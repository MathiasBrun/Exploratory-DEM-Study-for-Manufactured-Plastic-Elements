%% VIDEO DYNAMIC ANGLE OF REPOSE - ROTATING DRUM (BATCH PROCESSING)
% Batch video processing script: configure the first video once, then reuse
% that configuration for every video found under the main batch folder.
%
% WORKFLOW:
%   1. Set videoFolder to the main folder containing experiment folders
%   2. Run THIS SCRIPT and configure the first video
%   3. The first video's configuration is reused for every remaining video
%   4. Results are saved beside each source video


clear; close all; clc;

%% ---------------- USER INPUT ----------------
inputMode = 'video-folder';  % Batch mode uses all videos under videoFolder

% Normalize inputMode to prevent accidental fallback to images
inputMode = lower(strtrim(inputMode));
inputMode = strrep(inputMode, '_', '-');
inputMode = strrep(inputMode, ' ', '-');
validModes = {'images', 'video', 'video-folder'};
if ~any(strcmpi(inputMode, validModes))
    error('Invalid inputMode: %s. Use ''images'', ''video'', or ''video-folder''.', inputMode);
end

% Image folder settings
imageFolder = '/Users/andersriis/Desktop/DAoR/Video/TEST';  % Current folder - change to your image folder path
imageExtensions = {'*.jpg', '*.png', '*.bmp', '*.tiff', '*.tif'};  % Supported formats

% Video batch settings
% Set this to the main folder that contains your experiment folders.
% All supported videos in this folder and its subfolders will be processed.
videoFile = '/Users/andersriis/Desktop/DAoR/Video/Simulation/Test/20260430-1823-22.6440373.mp4';
videoFolder = ['/Users/andersriis/Desktop/DAoR/Data/Simulations/Ansys/Calibration_step_4/Flower'];
videoExtensions = {'*.mp4', '*.mov', '*.avi', '*.m4v'};
recursiveVideoSearch = true;
saveResultsNextToSourceVideo = true;
saveCombinedResultsFolder = true;  % Also copy CSV/MAT results into <input folder>_results
autoConvertUnreadableVideos = true;  % Convert unsupported codecs to H.264 when VideoReader cannot open them
convertedVideoFolderName = 'matlab_readable_videos';
ffmpegExecutable = '/opt/homebrew/bin/ffmpeg';
analyzeLastSeconds = 0;  % 0 = full video, otherwise analyze only last N seconds
analysisStartSeconds = 0;     % Used when videoTimeWindowMode = 'start-duration'
analysisDurationSeconds = 0;  % 0 = until end when videoTimeWindowMode = 'start-duration'
videoTimeWindowMode = 'full'; % 'full', 'last', or 'start-duration'
promptVideoTimeWindow = true; % Ask at runtime for video/video-folder inputs

skipFirstImages = 30;  % Skip first X images (images mode only)
skipLastImages = 30;   % Skip last X images (images mode only)
pauseFrequency = 0;  % Ask every X images if user wants to n
% 1
% continue (0 = no pauses)
minArea = 200;
smoothWindow = 80;
diameter_tolerance = 40;  % Accepted edge points must be at least this many pixels inside the drum radius
diameterTolerance = diameter_tolerance;
drumTolerance = diameterTolerance;  % Backward-compatible name used in saved result parameters
edgeThreshold = 0.10;      % Canny edge threshold for boundary detection
segmentationDilationRadius = 2;
segmentationClosingRadius = 4;
debugPreviewFrequency = 0; % Show debug preview every N frames (0 = off)
interactiveReview = true;         % Enable manual review for images/single video
reviewVideoFolderBatch = false;   % Keep false so video-folder batches continue automatically

% Flowing layer selection
yLower = 0.0;   % remove top crest
yUpper = 1;     % remove deep bulk

%% -------- OPTIMIZATION PARAMETERS --------
% These prevent MATLAB crashes on large image batches
maxImageWidth = 2500;   % Resize images wider than this (0 = disable, 1500-2000 recommended for 4K-6K images)
storeFrames = true;     % Store frames for interactive viewer (set to false only if severe memory issues)
clearMemory = true;     % Clear MATLAB cache every 20 images? (true helps with large batches)

%% -------- VALIDATION OPTIONS --------
% Verify that scaling doesn't affect angle measurements
runScalingValidation = false;  % Set to true to validate scaling consistency on first image

%% -------- IMAGE EXPORT OPTIONS --------
% Save annotated segmentation images showing analysis steps
exportSegmentationImages = false;  % Set to true to save annotated images showing segmentation
exportImageCount = 3;              % How many example images to export (first successful detections)
exportBaseFolder = 'segmentation_analysis';  % Folder to save annotated images
exportInitialFrameOverlays = true;  % Save first analyzed frame with shared drum/reference overlay for each video
initialFrameOverlayFolder = 'initial_frame_drum_overlays';
exportCalibrationImages = true;     % Save accepted color-calibration window, panels, and threshold values
calibrationExportFolder = 'calibration_export';

%% -------- COLOR CALIBRATION --------
% Set to true to force calibration before normal processing prompts
runColorCalibration = false;  % Set to true to find optimal HSV thresholds

if runColorCalibration
    fprintf('\n=== COLOR CALIBRATION MODE ===\n');
    fprintf('This will help you find the correct HSV thresholds for the selected material color.\n\n');
    % We'll load images first and then run calibration
end

%% ---------------- LOAD INPUT SOURCE ----------------
imageFiles = {};
videoFiles = {};
frameIndices = [];
videoObj = [];

if strcmpi(inputMode, 'video')
    videoFiles = {videoFile};
elseif strcmpi(inputMode, 'video-folder')
    if ~isfolder(videoFolder)
        error('Video folder not found: %s', videoFolder);
    end
    for ext = videoExtensions
        if recursiveVideoSearch
            files = dir(fullfile(videoFolder, '**', ext{1}));
        else
            files = dir(fullfile(videoFolder, ext{1}));
        end
        for i = 1:length(files)
            candidateVideoFile = fullfile(files(i).folder, files(i).name);
            if ~files(i).isdir && ~contains(candidateVideoFile, [filesep, convertedVideoFolderName, filesep])
                videoFiles{end+1} = candidateVideoFile;
            end
        end
    end
    if isempty(videoFiles)
        error('No video files found in folder: %s', videoFolder);
    end
    videoFiles = sort(videoFiles);
    fprintf('Found %d videos under batch folder: %s\n', numel(videoFiles), videoFolder);
else
    fprintf('Scanning folder: %s\n', imageFolder);

    for ext = imageExtensions
        files = dir(fullfile(imageFolder, ext{1}));
        for i = 1:length(files)
            if ~files(i).isdir
                imageFiles{end+1} = fullfile(files(i).folder, files(i).name);
            end
        end
    end

    if isempty(imageFiles)
        error('No image files found in folder: %s', imageFolder);
    end

    % Sort by filename
    [~, idx] = sort(cellfun(@(x) x, imageFiles, 'UniformOutput', false));
    imageFiles = imageFiles(idx);

    fprintf('Found %d images\n', length(imageFiles));

    % Skip first and last images if specified
    totalImages = length(imageFiles);
    if skipFirstImages > 0 || skipLastImages > 0
        startIdx = skipFirstImages + 1;
        endIdx = totalImages - skipLastImages;

        if startIdx > endIdx
            error('skipFirstImages + skipLastImages >= total images. Adjust parameters.');
        end

        fprintf('Skipping first %d and last %d images\n', skipFirstImages, skipLastImages);
        fprintf('Processing images %d to %d (%d images)\n', startIdx, endIdx, endIdx - startIdx + 1);

        imageFiles = imageFiles(startIdx:endIdx);
    end
end

resultsRootFolder = getResultsRootFolder(inputMode, imageFolder, videoFile, videoFolder);
if saveResultsNextToSourceVideo && strcmpi(inputMode, 'video-folder')
    fprintf('Results will be saved in the same folder as each source video.\n');
    if saveCombinedResultsFolder
        if ~isfolder(resultsRootFolder)
            mkdir(resultsRootFolder);
            fprintf('Created combined results folder: %s\n', resultsRootFolder);
        end
        fprintf('Combined CSV/MAT copies will also be saved to: %s\n', resultsRootFolder);
    end
else
    fprintf('Results root folder: %s\n', resultsRootFolder);
end

isVideoInput = strcmpi(inputMode, 'video') || strcmpi(inputMode, 'video-folder');
if isVideoInput && promptVideoTimeWindow
    fprintf('\n--- VIDEO TIME WINDOW ---\n');
    fprintf('  f = full video\n');
    fprintf('  l = last X seconds\n');
    fprintf('  s = start at X seconds and analyze Y seconds\n');
    modeInput = lower(strtrim(input('Select time-window mode (f/l/s, default = f): ', 's')));
    if isempty(modeInput)
        modeInput = 'f';
    end

    switch modeInput
        case {'f', 'full'}
            videoTimeWindowMode = 'full';
            analyzeLastSeconds = 0;
            analysisStartSeconds = 0;
            analysisDurationSeconds = 0;
            fprintf('Selected: analyze the full video.\n');

        case {'l', 'last'}
            videoTimeWindowMode = 'last';
            timeWindowInput = input(sprintf('Seconds to analyze from the end (default = %.3g): ', analyzeLastSeconds), 's');
            if ~isempty(strtrim(timeWindowInput))
                requestedLastSeconds = str2double(timeWindowInput);
                if isnan(requestedLastSeconds) || ~isfinite(requestedLastSeconds) || requestedLastSeconds <= 0
                    error('Invalid last-seconds window: %s. Enter a positive number of seconds.', timeWindowInput);
                end
                analyzeLastSeconds = requestedLastSeconds;
            elseif analyzeLastSeconds <= 0
                error('Last-seconds mode requires a positive number of seconds.');
            end
            fprintf('Selected: analyze only the last %.3g seconds of each video.\n', analyzeLastSeconds);

        case {'s', 'start', 'start-duration'}
            videoTimeWindowMode = 'start-duration';
            startInput = input(sprintf('Start analysis at seconds (default = %.3g): ', analysisStartSeconds), 's');
            if ~isempty(strtrim(startInput))
                requestedStart = str2double(startInput);
                if isnan(requestedStart) || ~isfinite(requestedStart) || requestedStart < 0
                    error('Invalid start time: %s. Enter a non-negative number of seconds.', startInput);
                end
                analysisStartSeconds = requestedStart;
            end

            durationInput = input(sprintf('Analyze duration in seconds (0 = until end, default = %.3g): ', analysisDurationSeconds), 's');
            if ~isempty(strtrim(durationInput))
                requestedDuration = str2double(durationInput);
                if isnan(requestedDuration) || ~isfinite(requestedDuration) || requestedDuration < 0
                    error('Invalid duration: %s. Enter 0 for until end or a positive number of seconds.', durationInput);
                end
                analysisDurationSeconds = requestedDuration;
            end

            if analysisDurationSeconds > 0
                fprintf('Selected: start at %.3g s and analyze %.3g s for each video.\n', analysisStartSeconds, analysisDurationSeconds);
            else
                fprintf('Selected: start at %.3g s and analyze until the end of each video.\n', analysisStartSeconds);
            end

        otherwise
            error('Invalid time-window mode: %s. Use f, l, or s.', modeInput);
    end
end

%% ---------------- PROCESS INPUTS ----------------
if isVideoInput
    runCount = numel(videoFiles);
else
    runCount = 1;
end

calibrationComplete = false;

for runIdx = 1:runCount
    if isVideoInput
        currentVideoFile = videoFiles{runIdx};
        currentVideoFolder = fileparts(currentVideoFile);
        readerVideoFile = currentVideoFile;
        overlayFile = '';
        if ~isfile(currentVideoFile)
            error('Video file not found: %s', currentVideoFile);
        end
        fprintf('\nVideo %d/%d: %s\n', runIdx, runCount, currentVideoFile);
        try
            [videoObj, readerVideoFile] = openVideoReaderWithFallback(currentVideoFile, ...
                autoConvertUnreadableVideos, convertedVideoFolderName, ffmpegExecutable);
        catch readerError
            if strcmpi(inputMode, 'video-folder')
                warning('Skipping unreadable video: %s\nReason: %s', currentVideoFile, readerError.message);
                continue;
            end
            rethrow(readerError);
        end
        totalFrames = max(1, floor(videoObj.Duration * videoObj.FrameRate));
        switch videoTimeWindowMode
            case 'last'
                startTime = max(0, videoObj.Duration - analyzeLastSeconds);
                endTime = videoObj.Duration;
            case 'start-duration'
                startTime = min(analysisStartSeconds, videoObj.Duration);
                if analysisDurationSeconds > 0
                    endTime = min(videoObj.Duration, startTime + analysisDurationSeconds);
                else
                    endTime = videoObj.Duration;
                end
            otherwise
                startTime = 0;
                endTime = videoObj.Duration;
        end
        if endTime <= startTime
            warning('Requested time window is empty for %s. Analyzing the final available frame instead.', currentVideoFile);
            startTime = max(0, videoObj.Duration - 1 / videoObj.FrameRate);
            endTime = videoObj.Duration;
        end
        endFrame = min(totalFrames, max(1, ceil(endTime * videoObj.FrameRate)));
        startFrame = min(endFrame, max(1, floor(startTime * videoObj.FrameRate) + 1));
        frameIndices = startFrame:endFrame;
        if ~strcmp(readerVideoFile, currentVideoFile)
            fprintf('VideoReader source: %s\n', readerVideoFile);
        end
        fprintf('Time window: %s (%.3f s to %.3f s of %.3f s)\n', ...
                describeVideoTimeWindow(videoTimeWindowMode, analyzeLastSeconds, analysisStartSeconds, analysisDurationSeconds), ...
                startTime, endTime, videoObj.Duration);
        fprintf('Frames: %d total, analyzing %d to %d (%d frames)\n', totalFrames, startFrame, endFrame, numel(frameIndices));
        currentInitialFrame = read(videoObj, frameIndices(1));
    else
        currentInitialFrame = imread(imageFiles{1});
    end

%% ---------------- LOAD AND ANALYZE FIRST IMAGE ----------------
if ~calibrationComplete
fprintf('\n--- ANALYZING FIRST IMAGE FOR CALIBRATION ---\n');

I_first = currentInitialFrame;

% Define reference line on first frame (optional)
skipRef = input('Skip reference line selection? (y/n): ', 's');
if strcmpi(skipRef, 'y') || strcmpi(skipRef, 'yes')
    mRef = 0;
    pRef = [0 0];
    fprintf('Reference line skipped. Using horizontal reference (slope = 0).\n');
else
    figure('Name','Select Reference Line');
    imshow(I_first);
    title('FIRST IMAGE: Click TWO points to define horizontal reference');

    [xRef, yRef] = ginput(2);
    pRef = polyfit(xRef, yRef, 1);
    mRef = pRef(1);
    fprintf('Reference line slope: %.6f\n', mRef);
end

% Define drum center and radius on first frame (drag-only adjustment)
if exist('drawcircle', 'file') ~= 2
    error('drawcircle is required for interactive drum setup. Install Image Processing Toolbox or update MATLAB.');
end

satisfied = false;
while ~satisfied
    fig = figure('Name','Adjust Drum Circle');
    imshow(I_first); hold on;
    hCircle = drawcircle('Center', [size(I_first, 2)/2, size(I_first, 1)/2], 'Radius', min(size(I_first, 1), size(I_first, 2))/3, ...
                         'Color', 'g', 'LineWidth', 2);
    title('Drag the circle to adjust. Double-click the circle when done.');
    hold off;

    wait(hCircle);
    cx = hCircle.Center(1);
    cy = hCircle.Center(2);
    r = hCircle.Radius;
    close(fig);

    % Show the defined circle
    figure('Name','Verify Drum Circle');
    imshow(I_first); hold on;

    theta = linspace(0, 2*pi, 100);
    circle_x = cx + r * cos(theta);
    circle_y = cy + r * sin(theta);
    plot(circle_x, circle_y, 'g-', 'LineWidth', 3, 'DisplayName', 'Drum Circle');
    plot(cx, cy, 'go', 'MarkerSize', 15, 'LineWidth', 2, 'DisplayName', 'Center');

    title(sprintf('Drum Circle: Center (%.0f, %.0f), Radius %.0f px', cx, cy, r));
    legend('Location', 'best');
    hold off;

    response = input('\nDoes the circle look correct? (y/n): ', 's');
    if strcmpi(response, 'y') || strcmpi(response, 'yes')
        satisfied = true;
        close all;
    else
        close all;
    end
end

fprintf('\n--- DRUM CIRCLE DEFINITION ---\n');
fprintf('Center: (%.1f, %.1f)\n', cx, cy);
fprintf('Radius: %.1f pixels\n', r);
close all;

%% -------- COLOR PRESET SELECTION --------
fprintf('\n--- BRICK COLOR PRESET ---\n');
fprintf('Select brick color: g = green, y = yellow, r = red\n');
colorChoice = input('Color choice (g/y/r, default = g): ', 's');
if isempty(colorChoice)
    colorChoice = 'g';
end

[hMin_preset, hMax_preset, sMin_preset, vMin_preset, colorLabel] = getColorPreset(colorChoice);
fprintf('Using %s preset: H=[%.3f, %.3f], S>%.3f, V>%.3f\n', colorLabel, hMin_preset, hMax_preset, sMin_preset, vMin_preset);

%% -------- INTERACTIVE COLOR CALIBRATION (OPTIONAL) --------
fprintf('\n--- COLOR CALIBRATION ---\n');
if runColorCalibration
    response = 'y';
else
    response = input('Would you like to calibrate color detection? (y/n): ', 's');
end

if strcmpi(response, 'y') || strcmpi(response, 'yes')
    calibrationExportDir = '';
    calibrationSourceLabel = 'calibration_frame';
    if exportCalibrationImages
        if isVideoInput && saveResultsNextToSourceVideo
            calibrationParentFolder = currentVideoFolder;
        else
            calibrationParentFolder = resultsRootFolder;
        end
        if ~isfolder(calibrationParentFolder)
            mkdir(calibrationParentFolder);
            fprintf('Created results root folder: %s\n', calibrationParentFolder);
        end
        calibrationExportDir = fullfile(calibrationParentFolder, calibrationExportFolder);
        if ~isfolder(calibrationExportDir)
            mkdir(calibrationExportDir);
            fprintf('Created calibration export folder: %s\n', calibrationExportDir);
        end

        if isVideoInput
            [~, calibrationSourceLabel, ~] = fileparts(currentVideoFile);
        else
            [~, calibrationSourceLabel, ~] = fileparts(imageFiles{1});
        end
    end

    [hMin_cal, hMax_cal, sMin_cal, vMin_cal, edgeThreshold_cal, dilationRadius_cal, closingRadius_cal, calibrationAccepted] = ...
        improvedColorCalibrationTool(I_first, mRef, cx, cy, r, minArea, smoothWindow, diameterTolerance, yLower, yUpper, ...
                                     hMin_preset, hMax_preset, sMin_preset, vMin_preset, colorLabel, edgeThreshold, ...
                                     segmentationDilationRadius, segmentationClosingRadius, ...
                                     calibrationExportDir, calibrationSourceLabel);
    
    if calibrationAccepted
        fprintf('✓ Color calibration accepted and will be used for batch processing.\n\n');
        % Store calibrated values
        hMin_custom = hMin_cal;
        hMax_custom = hMax_cal;
        sMin_custom = sMin_cal;
        vMin_custom = vMin_cal;
        edgeThreshold = edgeThreshold_cal;
        segmentationDilationRadius = dilationRadius_cal;
        segmentationClosingRadius = closingRadius_cal;
    else
        fprintf('Calibration cancelled. Using default thresholds.\n\n');
        % Use default values
        hMin_custom = hMin_preset;
        hMax_custom = hMax_preset;
        sMin_custom = sMin_preset;
        vMin_custom = vMin_preset;
    end
else
    fprintf('Using default color thresholds.\n\n');
    % Use default values
    hMin_custom = hMin_preset;
    hMax_custom = hMax_preset;
    sMin_custom = sMin_preset;
    vMin_custom = vMin_preset;
end

%% -------- SCALING VALIDATION (OPTIONAL) --------
if runScalingValidation
    fprintf('\n--- RUNNING SCALING VALIDATION ---\n');
    fprintf('Comparing angle measurements at different image scales...\n\n');
    
    validateScalingConsistency(I_first, mRef, cx, cy, r, minArea, smoothWindow, drumTolerance, yLower, yUpper, ...
                               hMin_custom, hMax_custom, sMin_custom, vMin_custom, edgeThreshold, ...
                               segmentationDilationRadius, segmentationClosingRadius);
    
    fprintf('\nValidation complete. Check results above.\n');
    fprintf('If angle differences are < 0.5°, scaling has minimal impact.\n\n');
end

calibrationComplete = true;
else
    fprintf('\n--- REUSING CALIBRATION FROM FIRST VIDEO ---\n');
    fprintf('Reference slope: %.6f\n', mRef);
    fprintf('Drum center: (%.1f, %.1f), radius: %.1f px, diameter: %.1f px\n', cx, cy, r, 2*r);
    fprintf('Diameter/drum tolerance: %.1f px\n', diameterTolerance);
    fprintf('Color preset/calibration: %s, H=[%.3f, %.3f], S>%.3f, V>%.3f\n', ...
            colorLabel, hMin_custom, hMax_custom, sMin_custom, vMin_custom);
    fprintf('Edge threshold: %.3f, dilation: %d, closing: %d\n', ...
            edgeThreshold, segmentationDilationRadius, segmentationClosingRadius);
end

%% -------- BATCH PROCESS IMAGES --------
fprintf('\n--- PROCESSING IMAGES ---\n');

isVideoMode = strcmpi(inputMode, 'video') || strcmpi(inputMode, 'video-folder');
if isVideoMode
    numImagesToAnalyze = numel(frameIndices);
else
    numImagesToAnalyze = length(imageFiles);
end

if isVideoMode
    [~, videoBaseName, ~] = fileparts(currentVideoFile);
    if saveResultsNextToSourceVideo
        resultsFolder = currentVideoFolder;
    else
        resultsFolder = fullfile(resultsRootFolder, videoBaseName);
    end
    if ~isfolder(resultsFolder)
        mkdir(resultsFolder);
        fprintf('Created results folder: %s\n', resultsFolder);
    end
    exportBaseFolderCurrent = fullfile(resultsFolder, [videoBaseName, '_', exportBaseFolder]);
else
    resultsFolder = resultsRootFolder;
    exportBaseFolderCurrent = exportBaseFolder;
end

if isVideoMode && exportInitialFrameOverlays
    initialOverlayDir = fullfile(resultsFolder, initialFrameOverlayFolder);
    if ~isfolder(initialOverlayDir)
        mkdir(initialOverlayDir);
        fprintf('Created initial-frame overlay folder: %s\n', initialOverlayDir);
    end
    overlayFile = exportInitialFrameDrumOverlay(currentInitialFrame, currentVideoFile, runIdx, runCount, ...
                                               pRef, mRef, cx, cy, r, diameterTolerance, ...
                                               videoTimeWindowMode, analyzeLastSeconds, analysisStartSeconds, analysisDurationSeconds, ...
                                               startTime, endTime, videoObj.Duration, ...
                                               initialOverlayDir);
    fprintf('✓ Initial frame drum overlay saved: %s\n', overlayFile);
end

angles = [];
densities = [];  % Store packing densities
imageNames = {};
frames = {};  % Store frame images
segmentationData = {};  % Store segmentation for each frame
processingTimes = [];  % Track time per image
scaleFactors = [];     % Track resize scale factor per image
frameTimes = [];       % Track frame time in seconds (video mode)
successCount = 0;
failCount = 0;
abortEarly = false;

for i = 1:numImagesToAnalyze
    if isVideoMode
        frameIdx = frameIndices(i);
        frame = read(videoObj, frameIdx);
        frameTime = (frameIdx - 1) / videoObj.FrameRate;
        fullImageName = sprintf('frame_%06d_t%.3fs', frameIdx, frameTime);
    else
        [~, imageName, ext] = fileparts(imageFiles{i});
        fullImageName = [imageName, ext];
    end
    iterationTic = tic;
    
    try
        % Read image
        if ~isVideoMode
            frame = imread(imageFiles{i});
        end
        
        % Convert to RGB if grayscale
        if size(frame, 3) == 1
            frame = cat(3, frame, frame, frame);
        end
        
        % === OPTIMIZATION: RESIZE LARGE IMAGES ===
        scaleFactor = 1.0;
        if maxImageWidth > 0 && size(frame, 2) > maxImageWidth
            scaleFactor = maxImageWidth / size(frame, 2);
            frame = imresize(frame, scaleFactor);
            fprintf('  → Resized to %.0f%% (scale: %.3f)\n', 100*scaleFactor, scaleFactor);
        end
        
        % Scale calibration parameters if image was resized
        % Slope is scale-invariant for uniform resize
        mRef_scaled = mRef;
        cx_scaled = cx * scaleFactor;
        cy_scaled = cy * scaleFactor;
        r_scaled = r * scaleFactor;
        drumTolerance_scaled = drumTolerance * scaleFactor;
        
        % Calculate angle and segmentation
        [theta, xBoundaryFiltered, yBoundaryFiltered, xBoundarySelected, yBoundarySelected, m] = ...
            calculateFrameAngle(frame, mRef_scaled, cx_scaled, cy_scaled, r_scaled, minArea, smoothWindow, drumTolerance_scaled, yLower, yUpper, ...
                                hMin_custom, hMax_custom, sMin_custom, vMin_custom, edgeThreshold, ...
                                segmentationDilationRadius, segmentationClosingRadius);

        % Optional debug preview
        if debugPreviewFrequency > 0 && mod(i, debugPreviewFrequency) == 0
            previewMask = createColorSegmentationMask(frame, hMin_custom, hMax_custom, sMin_custom, vMin_custom, ...
                                                      segmentationDilationRadius, segmentationClosingRadius, minArea);
            figure('Name', sprintf('Debug Preview %d', i));
            subplot(1, 2, 1);
            imshow(frame);
            title(sprintf('Frame %d', i));
            subplot(1, 2, 2);
            imshow(previewMask);
            title('Color Mask');
            drawnow;
        end
        
        if ~isnan(theta)
            % Calculate packing density
            density = calculateDensity(frame, cx_scaled, cy_scaled, r_scaled, hMin_custom, hMax_custom, sMin_custom, vMin_custom, ...
                                       minArea, segmentationDilationRadius, segmentationClosingRadius);
            
            angles(end+1) = theta;
            densities(end+1) = density;
            imageNames{end+1} = fullImageName;
            scaleFactors(end+1) = scaleFactor;
            if isVideoMode
                frameTimes(end+1) = frameTime;
            end
            
            % ONLY store frames if explicitly requested (saves memory)
            % Also store if exporting segmentation images
            if storeFrames || exportSegmentationImages
                frames{end+1} = frame;
            end
            
            % Store segmentation data (including scaled calibration for correct visualization)
            segmentationData{end+1} = struct(...
                'xBoundaryFiltered', xBoundaryFiltered, ...
                'yBoundaryFiltered', yBoundaryFiltered, ...
                'xBoundarySelected', xBoundarySelected, ...
                'yBoundarySelected', yBoundarySelected, ...
                'm', m, ...
                'density', density, ...
                'cx_scaled', cx_scaled, ...      % Scaled drum center
                'cy_scaled', cy_scaled, ...      % Scaled drum center
                'r_scaled', r_scaled, ...        % Scaled drum radius
                'mRef_scaled', mRef_scaled, ... % Scaled reference line slope
                'segmentationDilationRadius', segmentationDilationRadius, ...
                'segmentationClosingRadius', segmentationClosingRadius, ...
                'pRef_scaled', [pRef(1), pRef(2) * scaleFactor]); % Scaled reference line coefficients
            
            successCount = successCount + 1;
            iterTime = toc(iterationTic);
            processingTimes(end+1) = iterTime;
            fprintf('Image %3d/%d: %-40s  Angle = %.2f°  Density = %.1f%%  (%.2fs)\n', ...
                    i, numImagesToAnalyze, fullImageName, theta, density, iterTime);
        else
            failCount = failCount + 1;
            iterTime = toc(iterationTic);
            processingTimes(end+1) = iterTime;
            fprintf('Image %3d/%d: %-40s  FAILED (no valid detection) (%.2fs)\n', i, numImagesToAnalyze, fullImageName, iterTime);
        end
        
    catch ME
        failCount = failCount + 1;
        iterTime = toc(iterationTic);
        processingTimes(end+1) = iterTime;
        fprintf('Image %3d/%d: %-40s  ERROR: %s (%.2fs)\n', i, numImagesToAnalyze, fullImageName, ME.message, iterTime);
    end
    
    % === OPTIMIZATION: PERIODIC MEMORY CLEANUP ===
    if clearMemory && mod(i, 20) == 0
        pause(0.1);  % Let MATLAB perform housekeeping
    end
    
    % Ask user if they want to continue (at specified intervals)
    if pauseFrequency > 0 && mod(i, pauseFrequency) == 0 && i < numImagesToAnalyze
        fprintf('\n========================================\n');
        fprintf('Progress: %d/%d images processed (%.1f%%)\n', i, numImagesToAnalyze, 100*i/numImagesToAnalyze);
        fprintf('Successful: %d, Failed: %d\n', successCount, failCount);
        
        % Calculate timing statistics
        if length(processingTimes) > 0
            avgTime = mean(processingTimes);
            totalTime = sum(processingTimes);
            remainingImages = numImagesToAnalyze - i;
            estimatedRemaining = remainingImages * avgTime;
            imagesPerMin = 60 / avgTime;
            
            fprintf('\n--- PROCESSING SPEED ---\n');
            fprintf('Average time per image: %.2f s\n', avgTime);
            fprintf('Processing speed: %.1f images/min\n', imagesPerMin);
            fprintf('Time elapsed: %.1f min\n', totalTime/60);
            fprintf('Est. time remaining: %.1f min\n', estimatedRemaining/60);
        end
        
        choice = input('\nContinue analysis? (y/n/p): ', 's');  % p = preview results
        
        if strcmpi(choice, 'p')
            % Show quick preview
            if length(angles) > 0
                fprintf('\n--- CURRENT RESULTS PREVIEW ---\n');
                fprintf('Angle: Mean=%.2f°, Std=%.2f°, Range=[%.2f°, %.2f°]\n', ...
                    mean(angles), std(angles), min(angles), max(angles));
                fprintf('Density: Mean=%.1f%%, Std=%.1f%%, Range=[%.1f%%, %.1f%%]\n', ...
                    mean(densities), std(densities), min(densities), max(densities));
                fprintf('Correlation: %.3f\n', corr(densities', angles'));
            end
            
            % Ask again after preview
            choice = input('\nContinue analysis? (y/n): ', 's');
        end
        
        if strcmpi(choice, 'n') || strcmpi(choice, 'no')
            fprintf('\n--- ANALYSIS STOPPED BY USER ---\n');
            fprintf('Processed %d/%d images\n\n', i, numImagesToAnalyze);
            abortEarly = true;
            break;
        else
            fprintf('Continuing analysis...\n');
            fprintf('========================================\n\n');
        end
    end
end

if abortEarly
    fprintf('\nNote: Results are based on %d images processed before stopping.\n', i);
else
    fprintf('\nAll images processed.\n');
end

%% -------- EXPORT SEGMENTATION ANALYSIS IMAGES --------
if successCount > 0 && exportSegmentationImages
    fprintf('\n--- EXPORTING SEGMENTATION ANALYSIS IMAGES ---\n');
    
    % Create export folder
    if ~isfolder(exportBaseFolderCurrent)
        mkdir(exportBaseFolderCurrent);
        fprintf('Created folder: %s\n', exportBaseFolderCurrent);
    end
    
    % Export up to exportImageCount example images
    numToExport = min(exportImageCount, successCount);
    exportedCount = 0;
    
    for imgIdx = 1:length(frames)
        if exportedCount >= numToExport
            break;
        end
        
        % Create comprehensive visualization
        exportSegmentationVisualization(frames{imgIdx}, imageNames{imgIdx}, ...
                                       angles(imgIdx), densities(imgIdx), ...
                                       segmentationData{imgIdx}, cx, cy, r, ...
                                       pRef, mRef, exportBaseFolderCurrent, ...
                                       hMin_custom, hMax_custom, sMin_custom, vMin_custom);
        exportedCount = exportedCount + 1;
    end
    
    fprintf('✓ Exported %d example segmentation images to: %s/\n\n', exportedCount, exportBaseFolderCurrent);
end

%% -------- INTERACTIVE FRAME VIEWER --------
shouldRunInteractiveReview = interactiveReview && (~strcmpi(inputMode, 'video-folder') || reviewVideoFolderBatch);
if successCount > 0 && shouldRunInteractiveReview
    fprintf('\n--- LAUNCHING INTERACTIVE IMAGE VIEWER ---\n');
    
    % Ask user what they want to review
    fprintf('Review mode:\n');
    fprintf('  a = All images\n');
    fprintf('  o = Extreme outliers only (angle > 2 std dev)\n');
    reviewMode = input('Select mode (a/o): ', 's');
    
    if strcmpi(reviewMode, 'o')
        % Review outliers only
        fprintf('Reviewing extreme angle outliers...\n');
        [frames, imageNames, angles, densities, segmentationData, keepMask] = ...
            interactiveOutlierReviewer(frames, imageNames, angles, densities, segmentationData, pRef, mRef, cx, cy, r);
    else
        % Review all images
        fprintf('You can now review each image and delete measurements you disagree with.\n');
        [frames, imageNames, angles, densities, segmentationData, keepMask] = ...
            interactiveViewer(frames, imageNames, angles, densities, segmentationData, pRef, mRef, cx, cy, r);
    end

    if exist('keepMask', 'var') && numel(keepMask) == numel(scaleFactors)
        scaleFactors = scaleFactors(keepMask);
        if isVideoMode && ~isempty(frameTimes) && numel(keepMask) == numel(frameTimes)
            frameTimes = frameTimes(keepMask);
        end
    end
elseif successCount > 0 && ~shouldRunInteractiveReview
    fprintf('\n--- SKIPPING INTERACTIVE REVIEW FOR BATCH RUN ---\n');
    fprintf('Measurements will be saved automatically so the next video can start.\n');
end

%% -------- FINAL RESULTS (AFTER INTERACTIVE REVIEW) --------
fprintf('\n----- FINAL ANALYSIS RESULTS -----\n');

if abortEarly
    fprintf('Analysis type: PARTIAL (stopped early by user)\n');
else
    fprintf('Analysis type: COMPLETE\n');
end

fprintf('Images processed: %d\n', successCount + failCount);
fprintf('Successful detections: %d\n', successCount); 
fprintf('Failed detections: %d\n', failCount);
fprintf('After manual review: %d measurements retained\n', length(angles));

if length(angles) > 0
    avgAngle = mean(angles);
    stdAngle = std(angles);
    minAngle = min(angles);
    maxAngle = max(angles);
    
    avgDensity = mean(densities);
    stdDensity = std(densities);
    minDensity = min(densities);
    maxDensity = max(densities);
    
    fprintf('\nFinal Angle Statistics:\n');
    fprintf('  Average angle: %.2f degrees\n', avgAngle);
    fprintf('  Std deviation: %.2f degrees\n', stdAngle);
    fprintf('  Min angle:     %.2f degrees\n', minAngle);
    fprintf('  Max angle:     %.2f degrees\n', maxAngle);
    
    fprintf('\nFinal Density Statistics:\n');
    fprintf('  Average density: %.2f %%\n', avgDensity);
    fprintf('  Std deviation:   %.2f %%\n', stdDensity);
    fprintf('  Min density:     %.2f %%\n', minDensity);
    fprintf('  Max density:     %.2f %%\n', maxDensity);
    
    % Display timing statistics
    if length(processingTimes) > 0
        totalProcessingTime = sum(processingTimes);
        meanProcessingTime = mean(processingTimes);
        minProcessingTime = min(processingTimes);
        maxProcessingTime = max(processingTimes);
        imagesPerMinute = 60 / meanProcessingTime;
        
        fprintf('\nProcessing Performance:\n');
        fprintf('  Total time: %.2f minutes (%.2f hours)\n', totalProcessingTime/60, totalProcessingTime/3600);
        fprintf('  Average per image: %.2f seconds\n', meanProcessingTime);
        fprintf('  Fastest image: %.2f seconds\n', minProcessingTime);
        fprintf('  Slowest image: %.2f seconds\n', maxProcessingTime);
        fprintf('  Processing speed: %.1f images/minute\n', imagesPerMinute);
    end
else
    fprintf('ERROR: No measurements remaining!\n');
    return;
end

%% -------- ANALYSIS & VISUALIZATION --------
fprintf('\n========================================\n');
fprintf('✓ Data processing complete!\n');
fprintf('========================================\n\n');
fprintf('Next step: Run picture_DAoR_analysis.m\n');
fprintf('           to view plots and detailed statistics.\n\n');

%% -------- SAVE RESULTS --------
if successCount > 0
    % Create results folder if it doesn't exist
    if ~isfolder(resultsFolder)
        mkdir(resultsFolder);
        fprintf('Created results folder: %s\n', resultsFolder);
    end

    if isVideoMode
        baseName = getSegmentationResultsBaseName(currentVideoFolder);
    else
        baseName = getSegmentationResultsBaseName(imageFolder);
    end

    % Find next available results name
    suffix = 1;
    experimentName = baseName;
    while isfile(fullfile(resultsFolder, [experimentName, '.csv']))
        suffix = suffix + 1;
        experimentName = sprintf('%s_%d', baseName, suffix);
    end
    csvFile = fullfile(resultsFolder, [experimentName, '.csv']);
    matFile = fullfile(resultsFolder, [experimentName, '.mat']);
    
    fprintf('\nSaving as: %s\n', experimentName);
    
    % Create results table for CSV
    if isVideoMode && ~isempty(frameTimes)
        resultsTable = table(imageNames', frameTimes', angles', densities', scaleFactors', ...
                            'VariableNames', {'FrameName', 'Time_seconds', 'Angle_degrees', 'Density_percent', 'ScaleFactor'});
    else
        resultsTable = table(imageNames', angles', densities', scaleFactors', ...
                            'VariableNames', {'ImageName', 'Angle_degrees', 'Density_percent', 'ScaleFactor'});
    end
    
    % Save as CSV (human-readable)
    writetable(resultsTable, csvFile);
    fprintf('✓ CSV Results saved to: %s\n', csvFile);
    
    % Save as MAT file (includes all data for later analysis)
    
    % Package all results
    analysisResults = struct();
    analysisResults.imageNames = imageNames;
    analysisResults.angles = angles;
    analysisResults.densities = densities;
    analysisResults.scaleFactors = scaleFactors;
    analysisResults.segmentationData = segmentationData;
    analysisResults.processingTimes = processingTimes;
    
    % Calibration parameters (needed for visualization)
    analysisResults.calibration = struct();
    analysisResults.calibration.pRef = pRef;
    analysisResults.calibration.mRef = mRef;
    analysisResults.calibration.cx = cx;
    analysisResults.calibration.cy = cy;
    analysisResults.calibration.r = r;
    
    % Processing parameters
    analysisResults.parameters = struct();
    analysisResults.parameters.minArea = minArea;
    analysisResults.parameters.smoothWindow = smoothWindow;
    analysisResults.parameters.drumTolerance = drumTolerance;
    analysisResults.parameters.diameterTolerance = diameterTolerance;
    analysisResults.parameters.edgeThreshold = edgeThreshold;
    analysisResults.parameters.segmentationDilationRadius = segmentationDilationRadius;
    analysisResults.parameters.segmentationClosingRadius = segmentationClosingRadius;
    analysisResults.parameters.colorLabel = colorLabel;
    analysisResults.parameters.hMin = hMin_custom;
    analysisResults.parameters.hMax = hMax_custom;
    analysisResults.parameters.sMin = sMin_custom;
    analysisResults.parameters.vMin = vMin_custom;
    analysisResults.parameters.yLower = yLower;
    analysisResults.parameters.yUpper = yUpper;
    analysisResults.parameters.maxImageWidth = maxImageWidth;
    analysisResults.parameters.videoTimeWindowMode = videoTimeWindowMode;
    analysisResults.parameters.analyzeLastSeconds = analyzeLastSeconds;
    analysisResults.parameters.analysisStartSeconds = analysisStartSeconds;
    analysisResults.parameters.analysisDurationSeconds = analysisDurationSeconds;
    analysisResults.parameters.exportCalibrationImages = exportCalibrationImages;
    analysisResults.parameters.calibrationExportFolder = calibrationExportFolder;
    analysisResults.parameters.processingDate = datetime('now');
    
    analysisResults.summary = struct();
    analysisResults.summary.totalProcessed = successCount + failCount;
    analysisResults.summary.successCount = successCount;
    analysisResults.summary.failCount = failCount;
    
    analysisResults.imageFolder = imageFolder;
    if isVideoMode
        analysisResults.videoFile = currentVideoFile;
        if exist('readerVideoFile', 'var') && ~strcmp(readerVideoFile, currentVideoFile)
            analysisResults.readerVideoFile = readerVideoFile;
        end
        analysisResults.videoFolder = currentVideoFolder;
        analysisResults.batchRootFolder = videoFolder;
        analysisResults.videoDuration = videoObj.Duration;
        analysisResults.videoFrameRate = videoObj.FrameRate;
        analysisResults.analyzedStartTime = startTime;
        analysisResults.analyzedEndTime = endTime;
        analysisResults.analyzedDurationSeconds = endTime - startTime;
        analysisResults.analyzedStartFrame = startFrame;
        analysisResults.analyzedEndFrame = endFrame;
        if exist('overlayFile', 'var') && ~isempty(overlayFile)
            analysisResults.initialFrameOverlayFile = overlayFile;
        end
        analysisResults.frameTimes = frameTimes;
    end
    
    save(matFile, 'analysisResults', '-v7.3');
    fprintf('✓ MAT Results saved to: %s\n', matFile);

    if saveCombinedResultsFolder && saveResultsNextToSourceVideo && isVideoMode && ~strcmp(resultsFolder, resultsRootFolder)
        if ~isfolder(resultsRootFolder)
            mkdir(resultsRootFolder);
            fprintf('Created combined results folder: %s\n', resultsRootFolder);
        end

        combinedBaseName = experimentName;
        combinedExperimentName = combinedBaseName;
        combinedSuffix = 1;
        while isfile(fullfile(resultsRootFolder, [combinedExperimentName, '.csv'])) || ...
              isfile(fullfile(resultsRootFolder, [combinedExperimentName, '.mat']))
            combinedSuffix = combinedSuffix + 1;
            combinedExperimentName = sprintf('%s_%d', combinedBaseName, combinedSuffix);
        end

        combinedCsvFile = fullfile(resultsRootFolder, [combinedExperimentName, '.csv']);
        combinedMatFile = fullfile(resultsRootFolder, [combinedExperimentName, '.mat']);
        copyfile(csvFile, combinedCsvFile);
        copyfile(matFile, combinedMatFile);
        fprintf('✓ Combined CSV copy saved to: %s\n', combinedCsvFile);
        fprintf('✓ Combined MAT copy saved to: %s\n', combinedMatFile);
    end
    
    fprintf('\n--- NEXT STEPS ---\n');
    fprintf('1. Run "picture_DAoR_review.m" to visually review images with segmentation\n');
    fprintf('2. Run "picture_DAoR_analysis.m" to visualize and analyze the results\n');
    fprintf('3. Or open %s in a spreadsheet application to review data\n\n', csvFile);
end

end

if isVideoInput && ~calibrationComplete
    error('No readable videos were processed. If these are simulation videos, convert them to H.264 MP4 or install ffmpeg so the automatic conversion fallback can run.');
end

%% ========== CENTRALIZED HELPER FUNCTIONS (eliminate redundancy) ==========


function [videoObj, readerVideoFile] = openVideoReaderWithFallback(sourceVideoFile, autoConvertUnreadableVideos, convertedVideoFolderName, ffmpegExecutable)
    readerVideoFile = sourceVideoFile;
    try
        videoObj = VideoReader(sourceVideoFile);
        return;
    catch originalError
        if ~autoConvertUnreadableVideos
            rethrow(originalError);
        end

        fprintf('VideoReader could not open the source video: %s\n', originalError.message);
        convertedVideoFile = getConvertedVideoFile(sourceVideoFile, convertedVideoFolderName);

        sourceInfo = dir(sourceVideoFile);
        convertedInfo = dir(convertedVideoFile);
        needsConversion = isempty(convertedInfo) || convertedInfo.datenum < sourceInfo.datenum || convertedInfo.bytes == 0;
        if needsConversion
            convertVideoForMatlab(sourceVideoFile, convertedVideoFile, ffmpegExecutable);
        else
            fprintf('Using existing MATLAB-readable conversion: %s\n', convertedVideoFile);
        end

        try
            videoObj = VideoReader(convertedVideoFile);
            readerVideoFile = convertedVideoFile;
        catch convertedError
            error('Unable to open either the original video or the converted fallback. Original VideoReader error: %s Converted VideoReader error: %s', ...
                  originalError.message, convertedError.message);
        end
    end
end

function convertedVideoFile = getConvertedVideoFile(sourceVideoFile, convertedVideoFolderName)
    [sourceFolder, sourceBaseName, ~] = fileparts(sourceVideoFile);
    convertedFolder = fullfile(sourceFolder, convertedVideoFolderName);
    if ~isfolder(convertedFolder)
        mkdir(convertedFolder);
        fprintf('Created converted-video folder: %s\n', convertedFolder);
    end
    convertedVideoFile = fullfile(convertedFolder, [sourceBaseName, '_matlab_h264.mp4']);
end

function convertVideoForMatlab(sourceVideoFile, convertedVideoFile, ffmpegExecutable)
    fprintf('Converting to MATLAB-readable H.264 MP4: %s\n', convertedVideoFile);
    cmd = sprintf('%s -y -hide_banner -loglevel error -i %s -map 0:v:0 -an -vf %s -c:v libx264 -preset veryfast -crf 18 -pix_fmt yuv420p -movflags +faststart %s', ...
                  shellQuote(ffmpegExecutable), shellQuote(sourceVideoFile), shellQuote('pad=ceil(iw/2)*2:ceil(ih/2)*2'), shellQuote(convertedVideoFile));
    [status, output] = system(cmd);
    if status ~= 0
        if isfile(convertedVideoFile)
            delete(convertedVideoFile);
        end
        if isempty(strtrim(output))
            output = 'No ffmpeg output was returned.';
        end
        error('ffmpeg conversion failed. Install ffmpeg or manually convert this video to H.264 MP4. ffmpeg output: %s', output);
    end
end

function quotedValue = shellQuote(value)
    value = char(value);
    if contains(value, '''')
        error('ffmpeg fallback does not support paths containing single quotes: %s', value);
    end
    quotedValue = ['''', value, ''''];
end

function resultsRootFolder = getResultsRootFolder(inputMode, imageFolder, videoFile, videoFolder)
    % GETRESULTSROOTFOLDER - Name output folder after input folder + "_results"
    switch lower(strtrim(inputMode))
        case 'images'
            inputFolder = imageFolder;
        case 'video-folder'
            inputFolder = videoFolder;
        case 'video'
            inputFolder = fileparts(videoFile);
        otherwise
            inputFolder = pwd;
    end

    inputFolder = char(inputFolder);
    if isempty(inputFolder)
        inputFolder = pwd;
    end

    [parentFolder, inputFolderName] = fileparts(inputFolder);
    if isempty(inputFolderName)
        [parentFolder, inputFolderName] = fileparts(parentFolder);
    end
    if isempty(parentFolder)
        parentFolder = pwd;
    end

    resultsRootFolder = fullfile(parentFolder, [inputFolderName, '_results']);
end

function baseName = getSegmentationResultsBaseName(sourceFolder)
    % Name results from the two folders immediately above the source file.
    sourceFolder = char(sourceFolder);
    if isempty(sourceFolder)
        sourceFolder = pwd;
    end

    [parentFolder, sourceFolderName] = fileparts(sourceFolder);
    if isempty(sourceFolderName)
        [parentFolder, sourceFolderName] = fileparts(parentFolder);
    end

    [~, parentFolderName] = fileparts(parentFolder);
    if isempty(parentFolderName)
        parentFolderName = 'root';
    end

    baseName = sprintf('Segmentation_results_%s_%s', parentFolderName, sourceFolderName);
end

function description = describeVideoTimeWindow(videoTimeWindowMode, analyzeLastSeconds, analysisStartSeconds, analysisDurationSeconds)
    switch videoTimeWindowMode
        case 'last'
            description = sprintf('last %.3g seconds', analyzeLastSeconds);
        case 'start-duration'
            if analysisDurationSeconds > 0
                description = sprintf('start %.3g s, duration %.3g s', analysisStartSeconds, analysisDurationSeconds);
            else
                description = sprintf('start %.3g s, until end', analysisStartSeconds);
            end
        otherwise
            description = 'full video';
    end
end

function colorMask = createColorSegmentationMask(frame, hMin, hMax, sMin, vMin, dilationRadius, closingRadius, minArea)
    % CREATECOLORSEGMENTATIONMASK - Unified HSV material segmentation
    %
    % Supports normal hue ranges (hMin <= hMax) and wrap-around ranges such
    % as red (for example H=[0.95, 0.05]).
    
    if nargin < 8, minArea = 50; end
    if nargin < 7, closingRadius = 4; end
    if nargin < 6, dilationRadius = 2; end
    
    % Convert to HSV
    Ihsv = rgb2hsv(frame);
    H = Ihsv(:,:,1);
    S = Ihsv(:,:,2);
    V = Ihsv(:,:,3);
    
    % Apply HSV thresholds
    if hMin <= hMax
        hueMask = (H >= hMin) & (H <= hMax);
    else
        hueMask = (H >= hMin) | (H <= hMax);
    end

    colorMask = hueMask & (S > sMin) & (V > vMin);
    colorMask = imfill(colorMask, 'holes');
    colorMask = bwareaopen(colorMask, minArea);  % Remove small noise
    
    % Apply consistent morphological operations
    colorMask = imdilate(colorMask, strel('disk', dilationRadius));
    colorMask = imclose(colorMask, strel('disk', closingRadius));
    colorMask = imfill(colorMask, 'holes');
end

function greenMask = createGreenSegmentationMask(frame, hMin, hMax, sMin, vMin, dilationRadius, closingRadius, minArea)
    % Backward-compatible wrapper for older calls in this script/results.
    greenMask = createColorSegmentationMask(frame, hMin, hMax, sMin, vMin, dilationRadius, closingRadius, minArea);
end

function [edgeMask, xBoundary, yBoundary] = detectBoundaryEdgePoints(pileMask, edgeThreshold)
    % DETECTBOUNDARYEDGEPOINTS - Canny edge detection on segmented material
    if nargin < 2
        edgeThreshold = [];
    end

    try
        if isempty(edgeThreshold) || isnan(edgeThreshold)
            edgeMask = edge(pileMask, 'Canny');
        else
            edgeMask = edge(pileMask, 'Canny', edgeThreshold);
        end
    catch
        edgeMask = bwperim(pileMask, 8);
    end

    if ~any(edgeMask(:))
        edgeMask = bwperim(pileMask, 8);
    end

    [yBoundary, xBoundary] = find(edgeMask);
    xBoundary = xBoundary(:);
    yBoundary = yBoundary(:);

    if numel(xBoundary) < 20
        xBoundary = [];
        yBoundary = [];
    end
end

function [xFiltered, yFiltered] = filterBoundaryPointsWithinDrum(xBoundary, yBoundary, cx, cy, r, diameterTolerance)
    % FILTERBOUNDARYPOINTSWITHINDRUM - Keep edge points inside the usable drum diameter
    if nargin < 6, diameterTolerance = 0; end

    xBoundary = xBoundary(:);
    yBoundary = yBoundary(:);
    n = min(numel(xBoundary), numel(yBoundary));
    xBoundary = xBoundary(1:n);
    yBoundary = yBoundary(1:n);

    dist_to_center = sqrt((xBoundary - cx).^2 + (yBoundary - cy).^2);
    usableRadius = max(r - diameterTolerance, 1);
    validIdx = dist_to_center <= usableRadius;

    xFiltered = xBoundary(validIdx);
    yFiltered = yBoundary(validIdx);
end

function [xSurface, ySurface] = selectFreeSurfacePoints(xBoundary, yBoundary, cx, cy, r, smoothWindow, yLower, yUpper)
    % SELECTFREESURFACEPOINTS - Select top edge points for line fitting
    if nargin < 6, smoothWindow = 80; end
    if nargin < 7, yLower = 0.0; end
    if nargin < 8, yUpper = 1.0; end
    
    xBoundary = xBoundary(:);
    yBoundary = yBoundary(:);
    n = min(numel(xBoundary), numel(yBoundary));
    xBoundary = xBoundary(1:n);
    yBoundary = yBoundary(1:n);

    if isempty(xBoundary)
        xSurface = [];
        ySurface = [];
        return;
    end

    yNorm = (yBoundary - (cy - r)) ./ (2 * r);
    validY = (yNorm >= yLower) & (yNorm <= yUpper);
    xBoundary = xBoundary(validY);
    yBoundary = yBoundary(validY);

    if numel(xBoundary) < 20
        xSurface = [];
        ySurface = [];
        return;
    end

    xRounded = round(xBoundary);
    [xSurface, ~, groupIdx] = unique(xRounded);
    ySurface = accumarray(groupIdx, yBoundary, [], @min);

    [xSurface, sortIdx] = sort(xSurface(:));
    ySurface = ySurface(sortIdx);
    
    % Adaptive smoothing window
    nPoints = numel(ySurface);
    adaptiveWindow = max(round(nPoints * 0.05), 15);  % 5% of points, min 15
    adaptiveWindow = min(adaptiveWindow, smoothWindow);
    if mod(adaptiveWindow, 2) == 0
        adaptiveWindow = adaptiveWindow + 1;
    end
    
    if nPoints >= adaptiveWindow && adaptiveWindow >= 5
        yMedian = medfilt1(ySurface, min(5, round(adaptiveWindow/3)));
        ySurface = smoothdata(yMedian, 'sgolay', adaptiveWindow);
    end
end

function [m, b, inlierIdx] = fitRobustSurfaceLine(xSurface, ySurface)
    % FITROBUSTSURFACELINE - Two-pass line fit with residual outlier rejection
    xSurface = xSurface(:);
    ySurface = ySurface(:);
    n = min(numel(xSurface), numel(ySurface));
    xSurface = xSurface(1:n);
    ySurface = ySurface(1:n);

    if n < 20
        m = NaN;
        b = NaN;
        inlierIdx = false(size(xSurface));
        return;
    end

    p = polyfit(xSurface, ySurface, 1);
    residuals = ySurface - polyval(p, xSurface);
    sigma = 1.4826 * median(abs(residuals - median(residuals)));
    residualLimit = max(8, 3 * sigma);
    inlierIdx = abs(residuals) <= residualLimit;

    if sum(inlierIdx) >= 20
        p = polyfit(xSurface(inlierIdx), ySurface(inlierIdx), 1);
    else
        inlierIdx = true(size(xSurface));
    end

    m = p(1);
    b = p(2);
end

%% ========== ANGLE CALCULATION FUNCTION ==========

function [theta, xBoundaryFiltered, yBoundaryFiltered, xBoundarySelected, yBoundarySelected, m] = ...
    calculateFrameAngle(frame, mRef, cx, cy, r, minArea, smoothWindow, drumTolerance, yLower, yUpper, varargin)
    % CALCULATEFRAMEANGLE - Calculate angle of repose from image frame
    %
    % Inputs:
    %   frame            - Image frame (RGB)
    %   mRef             - Reference line slope
    %   cx, cy, r        - Drum circle parameters
    %   minArea, smoothWindow, drumTolerance, yLower, yUpper - Filter parameters
    %   hMin, hMax, sMin, vMin - (optional) HSV thresholds for color detection
    %   edgeThreshold - (optional) Canny threshold for boundary edge detection
    %   dilationRadius, closingRadius - (optional) segmentation morphology
    %
    % Outputs:
    %   theta - Angle of repose in degrees (NaN if detection fails)
    %   xBoundaryFiltered, yBoundaryFiltered - Boundary points after drum filtering
    %   xBoundarySelected, yBoundarySelected - Selected subset for fitting
    %   m - Fitted slope
    
    % Handle optional HSV parameters
    if nargin >= 14
        hMin = varargin{1};
        hMax = varargin{2};
        sMin = varargin{3};
        vMin = varargin{4};
    else
        % Default values
        hMin = 0.15;
        hMax = 0.40;
        sMin = 0.10;
        vMin = 0.20;
    end

    if numel(varargin) >= 5
        edgeThreshold = varargin{5};
    else
        edgeThreshold = 0.10;
    end
    if numel(varargin) >= 7
        dilationRadius = varargin{6};
        closingRadius = varargin{7};
    else
        dilationRadius = 2;
        closingRadius = 4;
    end

    % Create selected-color segmentation mask.
    colorMask = createColorSegmentationMask(frame, hMin, hMax, sMin, vMin, dilationRadius, closingRadius, minArea);
    
    % Keep largest connected component
    cc = bwconncomp(colorMask);
    if cc.NumObjects == 0
        theta = NaN;
        xBoundaryFiltered = [];
        yBoundaryFiltered = [];
        xBoundarySelected = [];
        yBoundarySelected = [];
        m = NaN;
        return;
    end
    
    stats = regionprops(cc, 'Area');
    [~, idxLargest] = max([stats.Area]);
    
    pileMask = false(size(colorMask));
    pileMask(cc.PixelIdxList{idxLargest}) = true;
    
    % Detect edge points on the segmented material boundary.
    [~, xBoundary, yBoundary] = detectBoundaryEdgePoints(pileMask, edgeThreshold);
    if numel(xBoundary) < 20
        theta = NaN;
        xBoundaryFiltered = [];
        yBoundaryFiltered = [];
        xBoundarySelected = [];
        yBoundarySelected = [];
        m = NaN;
        return;
    end
    
    % Keep only edge points inside the usable drum diameter.
    [xBoundaryFiltered, yBoundaryFiltered] = filterBoundaryPointsWithinDrum(xBoundary, yBoundary, cx, cy, r, drumTolerance);
    if numel(xBoundaryFiltered) < 20
        theta = NaN;
        xBoundarySelected = [];
        yBoundarySelected = [];
        m = NaN;
        return;
    end
    
    % Select the free-surface edge by keeping the upper edge point in each x-column.
    [xSurface, ySurface] = selectFreeSurfacePoints(xBoundaryFiltered, yBoundaryFiltered, cx, cy, r, smoothWindow, yLower, yUpper);
    if numel(xSurface) < 20
        theta = NaN;
        xBoundarySelected = [];
        yBoundarySelected = [];
        m = NaN;
        return;
    end
    
    % Fit line to the edge-detected free surface and calculate angle.
    [m, ~, inlierIdx] = fitRobustSurfaceLine(xSurface, ySurface);
    xBoundarySelected = xSurface(inlierIdx);
    yBoundarySelected = ySurface(inlierIdx);

    if isnan(m) || numel(xBoundarySelected) < 20
        theta = NaN;
        m = NaN;
        return;
    end

    theta = atan(abs((m - mRef) / (1 + m*mRef))) * 180/pi;
end

%% ========== DENSITY CALCULATION FUNCTION ==========

function density = calculateDensity(frame, cx, cy, r, varargin)
    % CALCULATEDENSITY - Calculate packing density within drum circle
    %
    % Usage: density = calculateDensity(frame, cx, cy, r)
    %        density = calculateDensity(frame, cx, cy, r, hMin, hMax, sMin, vMin)
    %        density = calculateDensity(frame, cx, cy, r, hMin, hMax, sMin, vMin, minArea)
    %        density = calculateDensity(frame, cx, cy, r, hMin, hMax, sMin, vMin, minArea, dilationRadius, closingRadius)
    %
    % Inputs:
    %   frame  - Image frame (RGB)
    %   cx, cy - Drum circle center coordinates
    %   r      - Drum circle radius
    %   hMin, hMax, sMin, vMin - (optional) HSV thresholds
    %
    % Output:
    %   density - Packing fraction as percentage (0-100)
    
    % Handle optional HSV parameters
    if nargin >= 9
        hMin = varargin{1};
        hMax = varargin{2};
        sMin = varargin{3};
        vMin = varargin{4};
        minArea = varargin{5};
        if numel(varargin) >= 7
            dilationRadius = varargin{6};
            closingRadius = varargin{7};
        else
            dilationRadius = 2;
            closingRadius = 4;
        end
    elseif nargin >= 8
        hMin = varargin{1};
        hMax = varargin{2};
        sMin = varargin{3};
        vMin = varargin{4};
        minArea = 50;
        dilationRadius = 2;
        closingRadius = 4;
    else
        % Default values
        hMin = 0.15;
        hMax = 0.40;
        sMin = 0.10;
        vMin = 0.20;
        minArea = 50;
        dilationRadius = 2;
        closingRadius = 4;
    end
    
    % Use centralized helper: Create selected-color segmentation mask
    % Ensures density calculated on same segmentation as angle measurement
    colorMask = createColorSegmentationMask(frame, hMin, hMax, sMin, vMin, dilationRadius, closingRadius, minArea);
    
    % Create drum circle mask
    [rows, cols, ~] = size(frame);
    [X, Y] = meshgrid(1:cols, 1:rows);
    distFromCenter = sqrt((X - cx).^2 + (Y - cy).^2);
    drumMask = distFromCenter <= r;
    
    % Count detected material pixels within drum
    colorWithinDrum = colorMask & drumMask;
    colorPixels = sum(colorWithinDrum(:));
    
    % Total pixels in drum
    totalDrumPixels = sum(drumMask(:));
    
    % Calculate packing density
    if totalDrumPixels > 0
        density = (colorPixels / totalDrumPixels) * 100;
    else
        density = 0;
    end
end

%% ========== INTERACTIVE VIEWER FUNCTION ==========

function [frames, imageNames, angles, densities, segmentationData, keepMask] = interactiveViewer(frames, imageNames, angles, densities, segmentationData, pRef, mRef, cx, cy, r)
    % INTERACTIVEVIEWER - Review analyzed images and reject bad measurements
    %
    % Usage: interactiveViewer(frames, imageNames, angles, densities, segmentationData, pRef, mRef, cx, cy, r)
    %
    % Inputs:
    %   frames               - Cell array of frame images
    %   imageNames           - Cell array of image filenames
    %   angles               - Array of calculated angles
    %   densities            - Array of packing density percentages
    %   segmentationData     - Cell array of struct with segmentation info
    %   pRef                 - Polynomial coefficients for reference line [slope, intercept]
    %   mRef                 - Slope of reference line
    %   cx, cy, r            - Drum circle center (cx, cy) and radius r
    
    if isempty(frames)
        fprintf('ERROR: No frames to display!\n');
        keepMask = true(size(angles));
        return;
    end
    
    % Initialize state
    currentIdx = 1;
    totalFrames = length(frames);
    deleted = false(totalFrames, 1);  % Track which measurements have been deleted
    
    % Create main figure
    fig = figure('Name', 'Interactive Image Review', 'NumberTitle', 'off', ...
                 'Position', [100, 100, 1200, 900]);
    
    % Create axes for image
    ax_img = subplot(2, 2, [1, 3]);
    
    % Create panel for controls and info
    ax_info = subplot(2, 2, 2);
    axis off;
    
    % Create axes for statistics
    ax_stats = subplot(2, 2, 4);
    axis off;
    
    % Main interactive loop
    while true
        % Update display
        updateDisplay(fig, ax_img, ax_info, ax_stats, currentIdx, ...
                     frames, imageNames, angles, densities, segmentationData, ...
                     deleted, pRef, mRef, cx, cy, r);
        
        % Wait for user input via keyboard
        try
            w = waitforbuttonpress;
            
            if w == 0  % Mouse click (not useful here)
                continue;
            end
            
            % Get the key that was pressed
            switch get(fig, 'CurrentCharacter')
                case 'n'  % Next frame
                    if currentIdx < totalFrames
                        currentIdx = currentIdx + 1;
                    end
                    
                case 'p'  % Previous frame
                    if currentIdx > 1
                        currentIdx = currentIdx - 1;
                    end
                    
                case 'd'  % Delete current measurement
                    if ~deleted(currentIdx)
                        deleted(currentIdx) = true;
                        fprintf('Image %s marked for deletion.\n', imageNames{currentIdx});
                        % Auto-advance to next non-deleted frame
                        if currentIdx < totalFrames
                            currentIdx = currentIdx + 1;
                        end
                    else
                        fprintf('Image %s already marked for deletion.\n', imageNames{currentIdx});
                    end
                    
                case 'u'  % Undo deletion
                    if deleted(currentIdx)
                        deleted(currentIdx) = false;
                        fprintf('Image %s restoration undone.\n', imageNames{currentIdx});
                    else
                        fprintf('Image %s not marked for deletion.\n', imageNames{currentIdx});
                    end
                    
                case 'q'  % Quit - finalize results
                    fprintf('\n--- REVIEW COMPLETE ---\n');
                    fprintf('Total images reviewed: %d\n', totalFrames);
                    fprintf('Images marked for deletion: %d\n', sum(deleted));
                    fprintf('Measurements retained: %d\n', totalFrames - sum(deleted));
                    
                    % Update arrays to remove deleted entries
                    keepMask = ~deleted(:)';
                    frames(deleted) = [];
                    imageNames(deleted) = [];
                    angles(deleted) = [];
                    densities(deleted) = [];
                    segmentationData(deleted) = [];
                    
                    % Close figure
                    close(fig);
                    
                    % Return to main script
                    return;
                    
                case 'h'  % Help / Show instructions
                    fprintf('\n--- INTERACTIVE VIEWER CONTROLS ---\n');
                    fprintf('  n  - Next image\n');
                    fprintf('  p  - Previous image\n');
                    fprintf('  d  - Delete (mark) current measurement\n');
                    fprintf('  u  - Undo deletion for current image\n');
                    fprintf('  h  - Show this help\n');
                    fprintf('  q  - Quit and finalize results\n');
                    fprintf('-----------------------------------\n\n');
            end
            
        catch
            % If figure is closed, break
            if ~isvalid(fig)
                break;
            end
        end
    end

    if ~exist('keepMask', 'var')
        keepMask = ~deleted(:)';
        frames(deleted) = [];
        imageNames(deleted) = [];
        angles(deleted) = [];
        densities(deleted) = [];
        segmentationData(deleted) = [];
    end
end

%% ========== UPDATE DISPLAY FUNCTION ==========

function updateDisplay(fig, ax_img, ax_info, ax_stats, currentIdx, ...
                      frames, imageNames, angles, densities, segmentationData, ...
                      deleted, pRef, mRef, cx, cy, r)
    % Clear axes
    cla(ax_img);
    cla(ax_info);
    cla(ax_stats);
    
    % Display image
    axes(ax_img);
    imshow(frames{currentIdx});
    title(sprintf('Image %d of %d: %s', currentIdx, length(frames), imageNames{currentIdx}), ...
          'FontSize', 12, 'FontWeight', 'bold');
    hold on;
    
    % Get segmentation data for current frame
    segData = segmentationData{currentIdx};
    xBoundaryFiltered = segData.xBoundaryFiltered;
    yBoundaryFiltered = segData.yBoundaryFiltered;
    xBoundarySelected = segData.xBoundarySelected;
    yBoundarySelected = segData.yBoundarySelected;
    m = segData.m;
    cx_scaled = segData.cx_scaled;
    cy_scaled = segData.cy_scaled;
    r_scaled = segData.r_scaled;
    pRef_scaled = segData.pRef_scaled;
    
    % Plot boundary points (all filtered points in cyan)
    if ~isempty(xBoundaryFiltered)
        plot(xBoundaryFiltered, yBoundaryFiltered, 'c.', 'MarkerSize', 6, 'DisplayName', 'Filtered boundary');
    end
    
    % Plot selected points (subset used for fitting in magenta)
    if ~isempty(xBoundarySelected)
        plot(xBoundarySelected, yBoundarySelected, 'm.', 'MarkerSize', 8, 'DisplayName', 'Selected points');
    end
    
    % Draw drum circle (using scaled coordinates)
    theta = linspace(0, 2*pi, 100);
    circleBoundary_x = cx_scaled + r_scaled * cos(theta);
    circleBoundary_y = cy_scaled + r_scaled * sin(theta);
    plot(circleBoundary_x, circleBoundary_y, 'y--', 'LineWidth', 2, 'DisplayName', 'Drum circle');
    
    % Draw fitted line for current frame
    if ~isempty(xBoundarySelected)
        x_line = linspace(min(xBoundarySelected)-50, max(xBoundarySelected)+50, 100);
        y_line = m * x_line + (mean(yBoundarySelected) - m * mean(xBoundarySelected));
        plot(x_line, y_line, 'r-', 'LineWidth', 2.5, 'DisplayName', 'Fitted line');
    end
    
    % Draw reference line (using scaled coefficients)
    x_ref = linspace(0, size(frames{currentIdx}, 2), 100);
    y_ref = polyval(pRef_scaled, x_ref);
    plot(x_ref, y_ref, 'w--', 'LineWidth', 2, 'DisplayName', 'Reference line');
    
    legend('Location', 'best');
    hold off;
    
    % Display info on side
    axes(ax_info);
    axis off;
    
    infoText = sprintf(['IMAGE INFORMATION\n' ...
                        '─────────────────────\n' ...
                        'Index: %d / %d\n' ...
                        'File: %s\n' ...
                        '\n' ...
                        'Measured Angle: %.2f°\n' ...
                        'Packing Density: %.1f%%\n' ...
                        'Reference Slope: %.6f\n' ...
                        'Fitted Slope: %.6f\n' ...
                        '\n' ...
                        'Status: %s\n' ...
                        '\n' ...
                        'CONTROLS:\n' ...
                        '─────────────────────\n' ...
                        'n - Next image\n' ...
                        'p - Previous image\n' ...
                        'd - Delete image\n' ...
                        'u - Undo deletion\n' ...
                        'h - Help\n' ...
                        'q - Quit & finalize\n'], ...
                       currentIdx, length(frames), imageNames{currentIdx}, ...
                       angles(currentIdx), densities(currentIdx), mRef, m, ...
                       iif(deleted(currentIdx), 'MARKED FOR DELETION', 'ACTIVE'));
    
    text(0.05, 0.5, infoText, 'FontName', 'Courier', 'FontSize', 10, ...
         'VerticalAlignment', 'middle', 'Parent', ax_info);
    
    % Display statistics
    axes(ax_stats);
    axis off;
    
    % Calculate statistics for non-deleted frames
    activeAngles = angles(~deleted);
    activeDensities = densities(~deleted);
    
    if ~isempty(activeAngles)
        currentStats = sprintf(['CURRENT STATISTICS\n' ...
                                '(Excluding deleted)\n' ...
                                '─────────────────────\n' ...
                                'Images: %d\n' ...
                                '\nANGLE:\n' ...
                                '  Mean: %.2f°\n' ...
                                '  Std Dev: %.2f°\n' ...
                                '  Min/Max: %.2f° / %.2f°\n' ...
                                '\nDENSITY:\n' ...
                                '  Mean: %.1f%%\n' ...
                                '  Std Dev: %.1f%%\n' ...
                                '  Min/Max: %.1f%% / %.1f%%\n'], ...
                               length(activeAngles), ...
                               mean(activeAngles), std(activeAngles), min(activeAngles), max(activeAngles), ...
                               mean(activeDensities), std(activeDensities), min(activeDensities), max(activeDensities));
    else
        currentStats = 'NO ACTIVE MEASUREMENTS';
    end
    
    text(0.05, 0.5, currentStats, 'FontName', 'Courier', 'FontSize', 10, ...
         'VerticalAlignment', 'middle', 'Parent', ax_stats, 'Color', 'red');
    
    drawnow;
end

%% ========== HELPER FUNCTION ==========

function result = iif(condition, trueVal, falseVal)
    % Inline if function
    if condition
        result = trueVal;
    else
        result = falseVal;
    end
end

%% ========== INTERACTIVE OUTLIER REVIEWER FUNCTION ==========

function [frames, imageNames, angles, densities, segmentationData, keepMask] = interactiveOutlierReviewer(frames, imageNames, angles, densities, segmentationData, pRef, mRef, cx, cy, r)
    % INTERACTIVEOUTLIERREVIEWER - Review only extreme angle outliers
    %
    % Usage: interactiveOutlierReviewer(frames, imageNames, angles, densities, segmentationData, pRef, mRef, cx, cy, r)
    %
    % Shows only angle outliers (> 2 std dev from mean) for verification
    % Allows deletion of outliers you don't agree with
    
    if isempty(frames)
        fprintf('ERROR: No frames to display!\n');
        keepMask = true(size(angles));
        return;
    end
    
    % Calculate angle statistics
    avgAngle = mean(angles);
    stdAngle = std(angles);
    
    % Find extreme angle outliers (beyond 2 std dev)
    angleOutliers = abs(angles - avgAngle) > 2 * stdAngle;
    outlierOriginalIndices = find(angleOutliers);
    
    if isempty(outlierOriginalIndices)
        fprintf('\n⚠ No extreme angle outliers detected (threshold: > 2 std dev)\n');
        fprintf('All angles are within normal range.\n\n');
        keepMask = true(size(angles));
        return;
    end
    
    fprintf('\n╔════════════════════════════════════╗\n');
    fprintf('║      EXTREME OUTLIER REVIEW        ║\n');
    fprintf('╚════════════════════════════════════╝\n');
    fprintf('Found %d extreme angle outlier(s) out of %d measurements (%.1f%%)\n\n', ...
            length(outlierOriginalIndices), length(angles), 100*length(outlierOriginalIndices)/length(angles));
    
    % Display outlier summary
    fprintf('Angle (°)    │ Z-Score\n');
    fprintf('─────────────┼──────────\n');
    for i = 1:length(outlierOriginalIndices)
        idx = outlierOriginalIndices(i);
        angleVal = angles(idx);
        zScore = (angleVal - avgAngle) / stdAngle;
        fprintf('%6.2f°      │ %+.2fσ\n', angleVal, zScore);
    end
    fprintf('\n');
    
    % Initialize state for outlier review
    currentOutlierIdx = 1;
    numOutliers = length(outlierOriginalIndices);
    deleted = false(length(frames), 1);  % Track deletions in original index space
    
    % Create main figure
    fig = figure('Name', 'Extreme Outlier Review', 'NumberTitle', 'off', ...
                 'Position', [100, 100, 1200, 900]);
    
    % Create axes for image
    ax_img = subplot(2, 2, [1, 3]);
    
    % Create panel for controls and info
    ax_info = subplot(2, 2, 2);
    axis off;
    
    % Create axes for statistics
    ax_stats = subplot(2, 2, 4);
    axis off;
    
    % Main interactive loop for outliers
    while true
        if currentOutlierIdx < 1 || currentOutlierIdx > numOutliers
            break;
        end
        
        % Get the original index of current outlier
        originalIdx = outlierOriginalIndices(currentOutlierIdx);
        
        % Update display
        updateOutlierDisplay(fig, ax_img, ax_info, ax_stats, currentOutlierIdx, numOutliers, ...
                            originalIdx, frames, imageNames, angles, densities, segmentationData, ...
                            deleted, pRef, mRef, cx, cy, r, avgAngle, stdAngle);
        
        % Wait for user input via keyboard
        try
            w = waitforbuttonpress;
            
            if w == 0  % Mouse click
                continue;
            end
            
            % Get the key that was pressed
            key = get(fig, 'CurrentKey');
            
            switch key
                case 'leftarrow'
                    currentOutlierIdx = currentOutlierIdx - 1;
                case 'rightarrow'
                    currentOutlierIdx = currentOutlierIdx + 1;
                case 'd'
                    % Delete this outlier
                    deleted(originalIdx) = true;
                    fprintf('Outlier image #%d marked for deletion\n', originalIdx);
                    currentOutlierIdx = currentOutlierIdx + 1;
                case 'g'
                    % Keep this outlier (confirmed as valid)
                    fprintf('Outlier image #%d confirmed as valid\n', originalIdx);
                    currentOutlierIdx = currentOutlierIdx + 1;
                case 'q'
                    % Quit and finalize
                    close(fig);
                    break;
            end
            
        catch
            % If figure is closed, break
            if ~isvalid(fig)
                break;
            end
        end
    end
    
    % Update the original arrays to remove marked outliers
    keepMask = ~deleted(:)';
    angles(deleted) = [];
    densities(deleted) = [];
    imageNames(deleted) = [];
    segmentationData(deleted) = [];
    frames(deleted) = [];
    
    numDeleted = sum(deleted);
    if numDeleted > 0
        fprintf('\n✓ Removed %d outlier measurement(s)\n', numDeleted);
        fprintf('Remaining measurements: %d\n\n', length(angles));
    else
        fprintf('\nNo outliers were deleted.\n\n');
    end
end

%% ========== UPDATE OUTLIER DISPLAY FUNCTION ==========

function updateOutlierDisplay(fig, ax_img, ax_info, ax_stats, currentOutlierIdx, numOutliers, ...
                             originalIdx, frames, imageNames, angles, densities, segmentationData, ...
                             deleted, pRef, mRef, cx, cy, r, avgAngle, stdAngle)
    % Clear axes
    cla(ax_img);
    cla(ax_info);
    cla(ax_stats);
    
    % Display image
    axes(ax_img);
    imshow(frames{originalIdx});
    title(sprintf('Outlier %d of %d: %s', currentOutlierIdx, numOutliers, imageNames{originalIdx}), ...
          'FontSize', 12, 'FontWeight', 'bold', 'Color', 'red');
    hold on;
    
    % Get segmentation data
    segData = segmentationData{originalIdx};
    xBoundaryFiltered = segData.xBoundaryFiltered;
    yBoundaryFiltered = segData.yBoundaryFiltered;
    xBoundarySelected = segData.xBoundarySelected;
    yBoundarySelected = segData.yBoundarySelected;
    m = segData.m;
    cx_scaled = segData.cx_scaled;
    cy_scaled = segData.cy_scaled;
    r_scaled = segData.r_scaled;
    pRef_scaled = segData.pRef_scaled;
    
    % Plot boundary points (all filtered points in cyan)
    if ~isempty(xBoundaryFiltered)
        plot(xBoundaryFiltered, yBoundaryFiltered, 'c.', 'MarkerSize', 6, 'DisplayName', 'Filtered boundary');
    end
    
    % Plot selected points (subset used for fitting in magenta)
    if ~isempty(xBoundarySelected)
        plot(xBoundarySelected, yBoundarySelected, 'm.', 'MarkerSize', 8, 'DisplayName', 'Selected points');
    end
    
    % Draw drum circle (using scaled coordinates)
    theta = linspace(0, 2*pi, 100);
    circleBoundary_x = cx_scaled + r_scaled * cos(theta);
    circleBoundary_y = cy_scaled + r_scaled * sin(theta);
    plot(circleBoundary_x, circleBoundary_y, 'y--', 'LineWidth', 2, 'DisplayName', 'Drum circle');
    
    % Draw fitted line
    if ~isempty(xBoundarySelected)
        x_line = linspace(min(xBoundarySelected)-50, max(xBoundarySelected)+50, 100);
        y_line = m * x_line + (mean(yBoundarySelected) - m * mean(xBoundarySelected));
        plot(x_line, y_line, 'r-', 'LineWidth', 2.5, 'DisplayName', 'Fitted line');
    end
    
    % Draw reference line (using scaled coefficients)
    x_ref = linspace(0, size(frames{originalIdx}, 2), 100);
    y_ref = polyval(pRef_scaled, x_ref);
    plot(x_ref, y_ref, 'w--', 'LineWidth', 2, 'DisplayName', 'Reference line');
    
    legend('Location', 'best');
    hold off;
    
    % Display info on side
    axes(ax_info);
    axis off;
    
    angleVal = angles(originalIdx);
    densityVal = densities(originalIdx);
    zScore = (angleVal - avgAngle) / stdAngle;
    
    infoText = sprintf(['OUTLIER INFORMATION\n' ...
                        '─────────────────────\n' ...
                        'Index: %d / %d\n' ...
                        'Original #: %d\n' ...
                        'File: %s\n' ...
                        '\n' ...
                        'Angle: %.2f°\n' ...
                        '  Mean: %.2f°\n' ...
                        '  Z-Score: %+.2fσ\n' ...
                        '\n' ...
                        'Density: %.1f%%\n' ...
                        '\n' ...
                        'Status: %s\n' ...
                        '\n' ...
                        'CONTROLS:\n' ...
                        '─────────────────────\n' ...
                        '← Previous  |  Next →\n' ...
                        'D: Delete   |  G: Keep\n' ...
                        'Q: Quit\n'], ...
                       currentOutlierIdx, numOutliers, originalIdx, imageNames{originalIdx}, ...
                       angleVal, avgAngle, zScore, densityVal, ...
                       iif(deleted(originalIdx), 'MARKED FOR DELETION', 'ACTIVE'));
    
    text(0.05, 0.5, infoText, 'FontName', 'Courier', 'FontSize', 10, ...
         'VerticalAlignment', 'middle', 'Parent', ax_info);
    
    % Display statistics
    axes(ax_stats);
    axis off;
    
    statsText = sprintf(['DATASET CONTEXT\n' ...
                         '─────────────────────\n' ...
                         'Total measurements: %d\n' ...
                         '\n' ...
                         'Angle statistics:\n' ...
                         '  Mean: %.2f°\n' ...
                         '  Std Dev: %.2f°\n' ...
                         '\n' ...
                         'This outlier:\n' ...
                         '  Deviation: %+.2f°\n' ...
                         '  Z-Score: %+.2fσ'], ...
                        length(angles), avgAngle, stdAngle, angleVal - avgAngle, zScore);
    
    text(0.05, 0.5, statsText, 'FontName', 'Courier', 'FontSize', 10, ...
         'VerticalAlignment', 'middle', 'Parent', ax_stats);
    
    drawnow;
end

%% ========== COLOR PRESET HELPER ==========

function [hMin, hMax, sMin, vMin, label] = getColorPreset(colorChoice)
    switch lower(strtrim(colorChoice))
        case {'g', 'green'}
            label = 'Green';
            hMin = 0.15; hMax = 0.40; sMin = 0.10; vMin = 0.20;
        case {'y', 'yellow'}
            label = 'Yellow';
            hMin = 0.12; hMax = 0.20; sMin = 0.25; vMin = 0.25;
        case {'r', 'red'}
            label = 'Red';
            hMin = 0.95; hMax = 0.05; sMin = 0.25; vMin = 0.25;
        otherwise
            label = 'Green';
            hMin = 0.15; hMax = 0.40; sMin = 0.10; vMin = 0.20;
    end
end

%% ========== IMPROVED COLOR CALIBRATION TOOL ==========

function [hMin, hMax, sMin, vMin, edgeThresholdOut, dilationRadiusOut, closingRadiusOut, accepted] = improvedColorCalibrationTool(frame, mRef, cx, cy, r, minArea, smoothWindow, drumTolerance, yLower, yUpper, varargin)
    % IMPROVEDCOLORCALIBRATIONTOOL - Interactive HSV + edge tracking tuning
    %
    % Provides real-time feedback showing:
    %   1. Selected-color detection mask
    %   2. Detected edges with control sliders
    %   3. Detected boundary points overlaid on original
    %   4. Angle measurement preview
    %   5. Coverage and edge statistics
    %
    % User can adjust both color thresholds AND edge detection parameters.
    
    Ihsv = rgb2hsv(frame);
    H = Ihsv(:,:,1);
    S = Ihsv(:,:,2);
    V = Ihsv(:,:,3);
    
    % Initial values (preset-based, can be overridden)
    hMin_val = 0.15;
    hMax_val = 0.40;
    sMin_val = 0.10;
    vMin_val = 0.20;
    colorLabel = 'Brick';

    if numel(varargin) >= 4
        hMin_val = varargin{1};
        hMax_val = varargin{2};
        sMin_val = varargin{3};
        vMin_val = varargin{4};
    end
    if numel(varargin) >= 5
        colorLabel = varargin{5};
    end
    
    % Edge detection parameters
    edgeThreshold = 0.1;  % Canny threshold (0-1)
    if numel(varargin) >= 6
        edgeThreshold = varargin{6};
    end
    edgeThresholdOut = edgeThreshold;
    morphRadius = 2;      % Morphological dilation radius (1-5)
    closingRadius = 4;
    if numel(varargin) >= 7
        morphRadius = varargin{7};
    end
    if numel(varargin) >= 8
        closingRadius = varargin{8};
    end
    dilationRadiusOut = morphRadius;
    closingRadiusOut = closingRadius;

    calibrationExportDir = '';
    calibrationSourceLabel = 'calibration_frame';
    if numel(varargin) >= 9 && (ischar(varargin{9}) || isstring(varargin{9}))
        calibrationExportDir = char(varargin{9});
    end
    if numel(varargin) >= 10 && (ischar(varargin{10}) || isstring(varargin{10}))
        calibrationSourceLabel = char(varargin{10});
    end
    
    accepted = false;
    
    % LARGER figure with better layout
    fig = figure('Name', [colorLabel, ' Brick Color Calibration - HSV + Edge Tracking'], 'NumberTitle', 'off', ...
                 'Position', [10, 50, 1920, 1080], 'CloseRequestFcn', @fig_close);
    
    % Create larger axes layout: 2 columns x 3 rows
    ax_original = subplot(3, 2, 1);
    ax_mask = subplot(3, 2, 2);
    ax_edge = subplot(3, 2, 3);
    ax_preview_boundary = subplot(3, 2, 4);
    ax_hist_hue = subplot(3, 2, 5);
    ax_info = subplot(3, 2, 6);
    
    % Control panel at bottom (HSV sliders)
    % H Min
    uicontrol(fig, 'Style', 'text', 'Position', [20, 210, 60, 20], 'String', 'H Min:', 'HorizontalAlignment', 'left', 'FontWeight', 'bold');
    slider_h_min = uicontrol(fig, 'Style', 'slider', 'Position', [90, 210, 200, 20], ...
        'Min', 0, 'Max', 1, 'Value', hMin_val, 'Callback', @(h,e) on_slider_changed());
    txt_hmin = uicontrol(fig, 'Style', 'edit', 'Position', [300, 210, 60, 20], 'String', sprintf('%.3f', hMin_val), 'Enable', 'off');
    
    % H Max
    uicontrol(fig, 'Style', 'text', 'Position', [20, 180, 60, 20], 'String', 'H Max:', 'HorizontalAlignment', 'left', 'FontWeight', 'bold');
    slider_h_max = uicontrol(fig, 'Style', 'slider', 'Position', [90, 180, 200, 20], ...
        'Min', 0, 'Max', 1, 'Value', hMax_val, 'Callback', @(h,e) on_slider_changed());
    txt_hmax = uicontrol(fig, 'Style', 'edit', 'Position', [300, 180, 60, 20], 'String', sprintf('%.3f', hMax_val), 'Enable', 'off');
    
    % S Min
    uicontrol(fig, 'Style', 'text', 'Position', [20, 150, 60, 20], 'String', 'S Min:', 'HorizontalAlignment', 'left', 'FontWeight', 'bold');
    slider_s_min = uicontrol(fig, 'Style', 'slider', 'Position', [90, 150, 200, 20], ...
        'Min', 0, 'Max', 1, 'Value', sMin_val, 'Callback', @(h,e) on_slider_changed());
    txt_smin = uicontrol(fig, 'Style', 'edit', 'Position', [300, 150, 60, 20], 'String', sprintf('%.3f', sMin_val), 'Enable', 'off');
    
    % V Min
    uicontrol(fig, 'Style', 'text', 'Position', [20, 120, 60, 20], 'String', 'V Min:', 'HorizontalAlignment', 'left', 'FontWeight', 'bold');
    slider_v_min = uicontrol(fig, 'Style', 'slider', 'Position', [90, 120, 200, 20], ...
        'Min', 0, 'Max', 1, 'Value', vMin_val, 'Callback', @(h,e) on_slider_changed());
    txt_vmin = uicontrol(fig, 'Style', 'edit', 'Position', [300, 120, 60, 20], 'String', sprintf('%.3f', vMin_val), 'Enable', 'off');
    
    % Edge Detection Sliders
    uicontrol(fig, 'Style', 'text', 'Position', [380, 210, 120, 20], 'String', 'EDGE TRACKING:', 'HorizontalAlignment', 'left', 'FontWeight', 'bold', 'ForegroundColor', 'red');
    
    % Edge Threshold
    uicontrol(fig, 'Style', 'text', 'Position', [380, 180, 120, 20], 'String', 'Canny Threshold:', 'HorizontalAlignment', 'left', 'FontWeight', 'bold');
    slider_edge_threshold = uicontrol(fig, 'Style', 'slider', 'Position', [520, 180, 150, 20], ...
        'Min', 0.01, 'Max', 0.5, 'Value', edgeThreshold, 'Callback', @(h,e) on_slider_changed());
    txt_edge_threshold = uicontrol(fig, 'Style', 'edit', 'Position', [680, 180, 60, 20], 'String', sprintf('%.3f', edgeThreshold), 'Enable', 'off');
    
    % Dilation Radius
    uicontrol(fig, 'Style', 'text', 'Position', [380, 150, 120, 20], 'String', 'Dilation Radius:', 'HorizontalAlignment', 'left', 'FontWeight', 'bold');
    slider_morph_radius = uicontrol(fig, 'Style', 'slider', 'Position', [520, 150, 150, 20], ...
        'Min', 1, 'Max', 5, 'Value', morphRadius, 'Callback', @(h,e) on_slider_changed());
    txt_morph_radius = uicontrol(fig, 'Style', 'edit', 'Position', [680, 150, 60, 20], 'String', sprintf('%.1f', morphRadius), 'Enable', 'off');
    
    % Buttons
    btn_accept = uicontrol(fig, 'Style', 'pushbutton', 'Position', [800, 180, 100, 30], ...
        'String', 'Accept', 'FontSize', 12, 'FontWeight', 'bold', 'BackgroundColor', [0.2, 0.8, 0.2], ...
        'Callback', @btn_accept_callback);
    
    btn_reject = uicontrol(fig, 'Style', 'pushbutton', 'Position', [920, 180, 100, 30], ...
        'String', 'Reject', 'FontSize', 12, 'FontWeight', 'bold', 'BackgroundColor', [0.8, 0.2, 0.2], ...
        'Callback', @btn_reject_callback);
    
    % Update function
    function updateDisplay()
        hMin_val = get(slider_h_min, 'Value');
        hMax_val = get(slider_h_max, 'Value');
        sMin_val = get(slider_s_min, 'Value');
        vMin_val = get(slider_v_min, 'Value');
        edgeThreshold = get(slider_edge_threshold, 'Value');
        morphRadius = round(get(slider_morph_radius, 'Value'));
        closingRadius = max(2, 2 * morphRadius);
        
        % Update display values
        set(txt_hmin, 'String', sprintf('%.3f', hMin_val));
        set(txt_hmax, 'String', sprintf('%.3f', hMax_val));
        set(txt_smin, 'String', sprintf('%.3f', sMin_val));
        set(txt_vmin, 'String', sprintf('%.3f', vMin_val));
        set(txt_edge_threshold, 'String', sprintf('%.3f', edgeThreshold));
        set(txt_morph_radius, 'String', sprintf('%.0f', morphRadius));
        
        % ===== PANEL 1: Original Image =====
        axes(ax_original);
        cla;
        imshow(frame);
        title('1. Original Image', 'FontSize', 14, 'FontWeight', 'bold');
        
        % ===== COLOR SEGMENTATION =====
        greenMask = createColorSegmentationMask(frame, hMin_val, hMax_val, sMin_val, vMin_val, ...
                                                morphRadius, closingRadius, max(minArea/2, 50));
        
        % ===== PANEL 2: Color Detection Mask =====
        axes(ax_mask);
        cla;
        imshow(greenMask);
        colormap(ax_mask, gray);
        title('2. Color Mask', 'FontSize', 14, 'FontWeight', 'bold');
        
        % ===== EDGE DETECTION and BOUNDARY EXTRACTION =====
        cc = bwconncomp(greenMask);
        if cc.NumObjects > 0
            stats = regionprops(cc, 'Area');
            [~, idxLargest] = max([stats.Area]);
            pileMask = false(size(greenMask));
            pileMask(cc.PixelIdxList{idxLargest}) = true;
            
            % Edge-detect the segmented material boundary
            [edgeMask, xBoundary, yBoundary] = detectBoundaryEdgePoints(pileMask, edgeThreshold);
            
            % ===== PANEL 3: Detected Boundary Points =====
            axes(ax_edge);
            cla;
            imshow(pileMask);
            colormap(ax_edge, gray);
            hold on;
            if ~isempty(xBoundary)
                plot(xBoundary, yBoundary, 'r.', 'MarkerSize', 6, 'DisplayName', sprintf('%d boundary points', numel(xBoundary)));
            end
            hold off;
            title('3. Boundary Points', 'FontSize', 14, 'FontWeight', 'bold');
            
            if numel(xBoundary) > 20
                [xBoundaryFiltered, yBoundaryFiltered] = filterBoundaryPointsWithinDrum(xBoundary, yBoundary, cx, cy, r, drumTolerance);

                if numel(xBoundaryFiltered) > 20
                    [xSurface, ySurface] = selectFreeSurfacePoints(xBoundaryFiltered, yBoundaryFiltered, cx, cy, r, smoothWindow, yLower, yUpper);
                    [m_measured, ~, inlierIdx] = fitRobustSurfaceLine(xSurface, ySurface);
                    xBoundarySelected = xSurface(inlierIdx);
                    yBoundarySelected = ySurface(inlierIdx);

                    if ~isnan(m_measured) && numel(xBoundarySelected) > 10
                        theta_preview = atan(abs((m_measured - mRef) / (1 + m_measured*mRef))) * 180/pi;
                    else
                        theta_preview = NaN;
                        xBoundarySelected = [];
                        yBoundarySelected = [];
                    end
                else
                    theta_preview = NaN;
                    xBoundaryFiltered = [];
                    yBoundaryFiltered = [];
                    xBoundarySelected = [];
                    yBoundarySelected = [];
                end
            else
                theta_preview = NaN;
                xBoundaryFiltered = [];
                yBoundaryFiltered = [];
                xBoundarySelected = [];
                yBoundarySelected = [];
            end
        else
            theta_preview = NaN;
            xBoundary = [];
            yBoundary = [];
            xBoundaryFiltered = [];
            yBoundaryFiltered = [];
            xBoundarySelected = [];
            yBoundarySelected = [];
            edgeMask = zeros(size(greenMask));
            axes(ax_edge);
            cla;
            imshow(edgeMask);
            title('3. Detected Edges', 'FontSize', 14, 'FontWeight', 'bold');
        end
        
        % ===== PANEL 4: Boundary Points Preview =====
        axes(ax_preview_boundary);
        cla;
        imshow(frame);
        title('4. Edge Tracking Preview', 'FontSize', 14, 'FontWeight', 'bold');
        hold on;
        if ~isempty(xBoundaryFiltered)
            plot(xBoundaryFiltered, yBoundaryFiltered, 'c.', 'MarkerSize', 6, 'DisplayName', sprintf('%d filtered', numel(xBoundaryFiltered)));
        end
        if ~isempty(xBoundarySelected)
            plot(xBoundarySelected, yBoundarySelected, 'm.', 'MarkerSize', 10, 'DisplayName', sprintf('%d selected', numel(xBoundarySelected)));
            x_line = linspace(min(xBoundarySelected)-50, max(xBoundarySelected)+50, 100);
            y_line = m_measured * x_line + (mean(yBoundarySelected) - m_measured * mean(xBoundarySelected));
            plot(x_line, y_line, 'r-', 'LineWidth', 2.5, 'DisplayName', sprintf('Angle: %.1f°', theta_preview));
        end
        theta_circ = linspace(0, 2*pi, 100);
        circle_x = cx + r * cos(theta_circ);
        circle_y = cy + r * sin(theta_circ);
        plot(circle_x, circle_y, 'y-', 'LineWidth', 2, 'DisplayName', 'Drum');
        legend('Location', 'best', 'FontSize', 9);
        hold off;
        
        % ===== PANEL 5: Hue Histogram =====
        axes(ax_hist_hue);
        cla;
        histogram(H(:), 150, 'FaceColor', [0.2, 0.8, 0.2], 'FaceAlpha', 0.7);
        hold on;
        plot([hMin_val hMin_val], ylim, 'r-', 'LineWidth', 3);
        plot([hMax_val hMax_val], ylim, 'r-', 'LineWidth', 3);
        hold off;
        xlabel('Hue', 'FontSize', 11);
        ylabel('Frequency', 'FontSize', 11);
        title('5. Hue Distribution', 'FontSize', 14, 'FontWeight', 'bold');
        xlim([0, 1]);
        
        % ===== PANEL 6: Information =====
        axes(ax_info);
        cla;
        axis off;
        
        greenPixels = sum(greenMask(:));
        totalPixels = numel(greenMask);
        coverage = 100 * greenPixels / totalPixels;
        edgePixels = sum(edgeMask(:));
        boundaryPoints = numel(xBoundary);
        if boundaryPoints == 0
            boundaryNote = 'No boundary points found';
        else
            boundaryNote = sprintf('Boundary points: %d', boundaryPoints);
        end
        
        if ~isnan(theta_preview)
            angleStr = sprintf('%.2f°', theta_preview);
        else
            angleStr = 'N/A';
        end
        
        infoText = sprintf(['COLOR & EDGE STATISTICS\n' ...
                            '═══════════════════════════════════\n' ...
                            'Detected Pixels: %d\n' ...
                            'Coverage: %.1f%%\n' ...
                            'Edge Pixels: %d\n' ...
                            '%s\n' ...
                            '\n' ...
                            'BOUNDARY DETECTION\n' ...
                            '───────────────────────────────────\n' ...
                            'Filtered Points: %d\n' ...
                            'Selected Points: %d\n' ...
                            'Angle Estimate: %s\n' ...
                            '\n' ...
                            'HSV THRESHOLDS\n' ...
                            '───────────────────────────────────\n' ...
                            'H: [%.3f, %.3f]\n' ...
                            'S: > %.3f\n' ...
                            'V: > %.3f\n' ...
                            '\n' ...
                            'EDGE PARAMETERS\n' ...
                            '───────────────────────────────────\n' ...
                            'Canny Threshold: %.3f\n' ...
                            'Dilation Radius: %d\n' ...
                            'Closing Radius: %d\n'], ...
                           greenPixels, coverage, edgePixels, boundaryNote, ...
                           numel(xBoundaryFiltered), numel(xBoundarySelected), angleStr, ...
                           hMin_val, hMax_val, sMin_val, vMin_val, ...
                           edgeThreshold, morphRadius, closingRadius);
        
        text(0.05, 0.5, infoText, 'FontName', 'Monospaced', 'FontSize', 10, ...
             'VerticalAlignment', 'middle', 'Parent', ax_info);
        
        drawnow limitrate;
    end
    
    % Slider callback
    function on_slider_changed()
        updateDisplay();
    end
    
    % Button callback for Accept
    function btn_accept_callback(~, ~)
        hMin = get(slider_h_min, 'Value');
        hMax = get(slider_h_max, 'Value');
        sMin = get(slider_s_min, 'Value');
        vMin = get(slider_v_min, 'Value');
        edgeThresholdOut = get(slider_edge_threshold, 'Value');
        dilationRadiusOut = round(get(slider_morph_radius, 'Value'));
        closingRadiusOut = max(2, 2 * dilationRadiusOut);
        accepted = true;
        
        fprintf('\n✓ Calibration accepted with values:\n');
        fprintf('  H: %.3f - %.3f\n', hMin, hMax);
        fprintf('  S: > %.3f\n', sMin);
        fprintf('  V: > %.3f\n', vMin);
        fprintf('  Edge threshold: %.3f\n', edgeThresholdOut);
        fprintf('  Segmentation morphology: dilation=%d, closing=%d\n\n', dilationRadiusOut, closingRadiusOut);

        if ~isempty(calibrationExportDir)
            updateDisplay();
            drawnow;
            try
                exportColorCalibrationArtifacts(frame, fig, calibrationExportDir, calibrationSourceLabel, colorLabel, ...
                                                hMin, hMax, sMin, vMin, edgeThresholdOut, dilationRadiusOut, closingRadiusOut, ...
                                                mRef, cx, cy, r, minArea, smoothWindow, drumTolerance, yLower, yUpper);
            catch ME
                warning('Could not export color calibration artifacts: %s', ME.message);
            end
        end
        
        closeCalibrationFigure();
    end
    
    % Button callback for Reject
    function btn_reject_callback(~, ~)
        accepted = false;
        closeCalibrationFigure();
    end
    
    % Figure close callback
    function fig_close(~, ~)
        if ~accepted
            accepted = false;
        end
        closeCalibrationFigure();
    end

    function closeCalibrationFigure()
        if exist('fig', 'var') && isgraphics(fig)
            set(fig, 'CloseRequestFcn', '');
            delete(fig);
        end
    end
    
    % Initial display
    fprintf('\n╔══════════════════════════════════════════════════╗\n');
    fprintf('║  INTERACTIVE COLOR + EDGE CALIBRATION TOOL    ║\n');
    fprintf('╚══════════════════════════════════════════════════╝\n\n');
    fprintf('Instructions:\n');
    fprintf('  • Adjust HSV sliders to improve %s detection\n', lower(colorLabel));
    fprintf('  • Adjust Canny Threshold to improve edge following\n');
    fprintf('  • Adjust Dilation Radius to control edge thickness\n');
    fprintf('  • Watch the 6 panels for real-time feedback\n');
    fprintf('  • Check the angle estimate and boundary points\n');
    fprintf('  • Click Accept to use these settings\n\n');
    
    updateDisplay();
    uiwait(fig);
end

%% ========== COLOR CALIBRATION EXPORT FUNCTION ==========

function exportColorCalibrationArtifacts(frame, calibrationFig, exportFolder, sourceLabel, colorLabel, ...
                                         hMin, hMax, sMin, vMin, edgeThreshold, dilationRadius, closingRadius, ...
                                         mRef, cx, cy, r, minArea, smoothWindow, drumTolerance, yLower, yUpper)
    % EXPORTCOLORCALIBRATIONARTIFACTS - Save accepted calibration preview and final thresholds
    if ~isfolder(exportFolder)
        mkdir(exportFolder);
    end

    safeSourceLabel = makeSafeFileName(sourceLabel);
    timestampLabel = datestr(now, 'yyyymmdd_HHMMSS');
    runExportFolder = fullfile(exportFolder, sprintf('%s_%s', safeSourceLabel, timestampLabel));
    if ~isfolder(runExportFolder)
        mkdir(runExportFolder);
    end

    if ishandle(calibrationFig)
        try
            windowFrame = getframe(calibrationFig);
            imwrite(windowFrame.cdata, fullfile(runExportFolder, '01_calibration_window.png'));
        catch
            print(calibrationFig, fullfile(runExportFolder, '01_calibration_window.png'), '-dpng', '-r200');
        end
    end

    Ihsv = rgb2hsv(frame);
    H = Ihsv(:,:,1);

    colorMask = createColorSegmentationMask(frame, hMin, hMax, sMin, vMin, ...
                                            dilationRadius, closingRadius, max(minArea/2, 50));
    pileMask = false(size(colorMask));
    edgeMask = false(size(colorMask));
    xBoundary = [];
    yBoundary = [];
    xBoundaryFiltered = [];
    yBoundaryFiltered = [];
    xBoundarySelected = [];
    yBoundarySelected = [];
    mMeasured = NaN;
    bMeasured = NaN;
    thetaPreview = NaN;

    cc = bwconncomp(colorMask);
    if cc.NumObjects > 0
        ccStats = regionprops(cc, 'Area');
        [~, idxLargest] = max([ccStats.Area]);
        pileMask(cc.PixelIdxList{idxLargest}) = true;

        [edgeMask, xBoundary, yBoundary] = detectBoundaryEdgePoints(pileMask, edgeThreshold);
        if numel(xBoundary) > 20
            [xBoundaryFiltered, yBoundaryFiltered] = filterBoundaryPointsWithinDrum(xBoundary, yBoundary, cx, cy, r, drumTolerance);
            if numel(xBoundaryFiltered) > 20
                [xSurface, ySurface] = selectFreeSurfacePoints(xBoundaryFiltered, yBoundaryFiltered, cx, cy, r, smoothWindow, yLower, yUpper);
                [mMeasured, bMeasured, inlierIdx] = fitRobustSurfaceLine(xSurface, ySurface);
                if ~isnan(mMeasured) && numel(inlierIdx) == numel(xSurface)
                    xBoundarySelected = xSurface(inlierIdx);
                    yBoundarySelected = ySurface(inlierIdx);
                    if numel(xBoundarySelected) > 10
                        thetaPreview = atan(abs((mMeasured - mRef) / (1 + mMeasured*mRef))) * 180/pi;
                    end
                end
            end
        end
    end

    greenPixels = sum(colorMask(:));
    totalPixels = numel(colorMask);
    coverage = 100 * greenPixels / totalPixels;
    edgePixels = sum(edgeMask(:));

    values = struct();
    values.sourceLabel = sourceLabel;
    values.colorLabel = colorLabel;
    values.hMin = hMin;
    values.hMax = hMax;
    values.sMin = sMin;
    values.vMin = vMin;
    values.edgeThreshold = edgeThreshold;
    values.segmentationDilationRadius = dilationRadius;
    values.segmentationClosingRadius = closingRadius;
    values.minArea = minArea;
    values.smoothWindow = smoothWindow;
    values.drumTolerance = drumTolerance;
    values.yLower = yLower;
    values.yUpper = yUpper;
    values.maskPixels = greenPixels;
    values.maskCoveragePercent = coverage;
    values.edgePixels = edgePixels;
    values.boundaryPoints = numel(xBoundary);
    values.filteredBoundaryPoints = numel(xBoundaryFiltered);
    values.selectedBoundaryPoints = numel(xBoundarySelected);
    values.previewAngleDegrees = thetaPreview;
    values.referenceSlope = mRef;
    values.drumCenterX = cx;
    values.drumCenterY = cy;
    values.drumRadiusPixels = r;
    values.exportedAt = datestr(now, 'yyyy-mm-dd HH:MM:SS');

    parameterNames = { ...
        'source_label'; 'color_label'; 'h_min'; 'h_max'; 's_min'; 'v_min'; ...
        'edge_threshold'; 'segmentation_dilation_radius'; 'segmentation_closing_radius'; ...
        'min_area'; 'smooth_window'; 'drum_tolerance'; 'y_lower'; 'y_upper'; ...
        'mask_pixels'; 'mask_coverage_percent'; 'edge_pixels'; 'boundary_points'; ...
        'filtered_boundary_points'; 'selected_boundary_points'; 'preview_angle_degrees'; ...
        'reference_slope'; 'drum_center_x'; 'drum_center_y'; 'drum_radius_pixels'; 'exported_at'};
    parameterValues = { ...
        char(sourceLabel); char(colorLabel); sprintf('%.6f', hMin); sprintf('%.6f', hMax); ...
        sprintf('%.6f', sMin); sprintf('%.6f', vMin); sprintf('%.6f', edgeThreshold); ...
        sprintf('%d', dilationRadius); sprintf('%d', closingRadius); sprintf('%.6f', minArea); ...
        sprintf('%.6f', smoothWindow); sprintf('%.6f', drumTolerance); sprintf('%.6f', yLower); ...
        sprintf('%.6f', yUpper); sprintf('%d', greenPixels); sprintf('%.6f', coverage); ...
        sprintf('%d', edgePixels); sprintf('%d', numel(xBoundary)); sprintf('%d', numel(xBoundaryFiltered)); ...
        sprintf('%d', numel(xBoundarySelected)); sprintf('%.6f', thetaPreview); sprintf('%.9f', mRef); ...
        sprintf('%.6f', cx); sprintf('%.6f', cy); sprintf('%.6f', r); values.exportedAt};
    calibrationTable = table(parameterNames, parameterValues, 'VariableNames', {'Parameter', 'Value'});
    writetable(calibrationTable, fullfile(runExportFolder, 'calibration_values.csv'));
    save(fullfile(runExportFolder, 'calibration_values.mat'), 'values');

    fid = fopen(fullfile(runExportFolder, 'calibration_values.txt'), 'w');
    if fid ~= -1
        fprintf(fid, 'Color calibration export\n');
        fprintf(fid, 'Source: %s\n', sourceLabel);
        fprintf(fid, 'Color: %s\n\n', colorLabel);
        fprintf(fid, 'HSV thresholds\n');
        fprintf(fid, '  H: [%.6f, %.6f]\n', hMin, hMax);
        fprintf(fid, '  S: > %.6f\n', sMin);
        fprintf(fid, '  V: > %.6f\n\n', vMin);
        fprintf(fid, 'Edge and morphology\n');
        fprintf(fid, '  Canny threshold: %.6f\n', edgeThreshold);
        fprintf(fid, '  Dilation radius: %d\n', dilationRadius);
        fprintf(fid, '  Closing radius: %d\n\n', closingRadius);
        fprintf(fid, 'Preview statistics\n');
        fprintf(fid, '  Mask coverage: %.3f %%\n', coverage);
        fprintf(fid, '  Boundary points: %d\n', numel(xBoundary));
        fprintf(fid, '  Filtered boundary points: %d\n', numel(xBoundaryFiltered));
        fprintf(fid, '  Selected boundary points: %d\n', numel(xBoundarySelected));
        fprintf(fid, '  Preview angle: %.6f degrees\n', thetaPreview);
        fclose(fid);
    end

    figOriginal = figure('Visible', 'off', 'Units', 'inches', 'Position', [0, 0, 8, 5.5]);
    imshow(frame);
    title(sprintf('Original calibration frame: %s', sourceLabel), 'Interpreter', 'none');
    printCalibrationFigure(figOriginal, fullfile(runExportFolder, '02_original_frame.png'), 200);
    close(figOriginal);

    figMask = figure('Visible', 'off', 'Units', 'inches', 'Position', [0, 0, 8, 5.5]);
    imshow(colorMask);
    colormap(gca, gray);
    title(sprintf('%s color mask, H=[%.3f, %.3f], S>%.3f, V>%.3f', colorLabel, hMin, hMax, sMin, vMin), 'Interpreter', 'none');
    printCalibrationFigure(figMask, fullfile(runExportFolder, '03_color_mask.png'), 200);
    close(figMask);

    figBoundary = figure('Visible', 'off', 'Units', 'inches', 'Position', [0, 0, 8, 5.5]);
    imshow(pileMask);
    colormap(gca, gray);
    hold on;
    if ~isempty(xBoundary)
        plot(xBoundary, yBoundary, 'r.', 'MarkerSize', 5, 'DisplayName', sprintf('%d boundary points', numel(xBoundary)));
        legend('Location', 'best');
    end
    hold off;
    title('Detected material boundary points');
    printCalibrationFigure(figBoundary, fullfile(runExportFolder, '04_boundary_points.png'), 200);
    close(figBoundary);

    figPreview = figure('Visible', 'off', 'Units', 'inches', 'Position', [0, 0, 8, 5.5]);
    imshow(frame);
    hold on;
    if ~isempty(xBoundaryFiltered)
        plot(xBoundaryFiltered, yBoundaryFiltered, 'c.', 'MarkerSize', 5, 'DisplayName', sprintf('%d filtered', numel(xBoundaryFiltered)));
    end
    if ~isempty(xBoundarySelected)
        plot(xBoundarySelected, yBoundarySelected, 'm.', 'MarkerSize', 8, 'DisplayName', sprintf('%d selected', numel(xBoundarySelected)));
        x_line = linspace(min(xBoundarySelected)-50, max(xBoundarySelected)+50, 100);
        y_line = mMeasured * x_line + bMeasured;
        plot(x_line, y_line, 'r-', 'LineWidth', 2.0, 'DisplayName', sprintf('Angle %.2f deg', thetaPreview));
    end
    thetaCircle = linspace(0, 2*pi, 200);
    plot(cx + r*cos(thetaCircle), cy + r*sin(thetaCircle), 'y-', 'LineWidth', 2, 'DisplayName', 'Drum');
    legend('Location', 'best');
    hold off;
    title('Accepted edge tracking preview');
    printCalibrationFigure(figPreview, fullfile(runExportFolder, '05_edge_tracking_preview.png'), 200);
    close(figPreview);

    figHist = figure('Visible', 'off', 'Units', 'inches', 'Position', [0, 0, 8, 5.5]);
    histogram(H(:), 150, 'FaceColor', [0.25, 0.45, 0.60], 'EdgeColor', 'none', 'FaceAlpha', 0.75);
    hold on;
    yLimits = ylim;
    plot([hMin hMin], yLimits, 'r-', 'LineWidth', 2.0, 'DisplayName', 'H min');
    plot([hMax hMax], yLimits, 'r--', 'LineWidth', 2.0, 'DisplayName', 'H max');
    hold off;
    xlim([0, 1]);
    xlabel('Hue');
    ylabel('Frequency');
    title('Hue distribution with accepted limits');
    legend('Location', 'best');
    printCalibrationFigure(figHist, fullfile(runExportFolder, '06_hue_histogram.png'), 200);
    close(figHist);

    figInfo = figure('Visible', 'off', 'Units', 'inches', 'Position', [0, 0, 8, 5.5]);
    axis off;
    if isnan(thetaPreview)
        angleText = 'N/A';
    else
        angleText = sprintf('%.2f deg', thetaPreview);
    end
    infoText = sprintf(['ACCEPTED COLOR CALIBRATION\n\n' ...
                        'Source: %s\n' ...
                        'Color preset: %s\n\n' ...
                        'HSV thresholds:\n' ...
                        '  H: [%.3f, %.3f]\n' ...
                        '  S: > %.3f\n' ...
                        '  V: > %.3f\n\n' ...
                        'Edge parameters:\n' ...
                        '  Canny threshold: %.3f\n' ...
                        '  Dilation radius: %d\n' ...
                        '  Closing radius: %d\n\n' ...
                        'Preview statistics:\n' ...
                        '  Mask coverage: %.2f %%\n' ...
                        '  Boundary points: %d\n' ...
                        '  Filtered points: %d\n' ...
                        '  Selected points: %d\n' ...
                        '  Preview angle: %s\n'], ...
                        sourceLabel, colorLabel, hMin, hMax, sMin, vMin, edgeThreshold, ...
                        dilationRadius, closingRadius, coverage, numel(xBoundary), ...
                        numel(xBoundaryFiltered), numel(xBoundarySelected), angleText);
    text(0.05, 0.95, infoText, 'Units', 'normalized', 'FontName', 'Monospaced', ...
         'FontSize', 12, 'VerticalAlignment', 'top', 'Interpreter', 'none');
    printCalibrationFigure(figInfo, fullfile(runExportFolder, '07_calibration_values_summary.png'), 200);
    close(figInfo);

    fprintf('✓ Color calibration export saved to: %s\n', runExportFolder);
end

function safeName = makeSafeFileName(rawName)
    safeName = regexprep(char(rawName), '[^A-Za-z0-9_-]', '_');
    if isempty(safeName)
        safeName = 'calibration';
    end
end

function printCalibrationFigure(figHandle, outputPath, resolution)
    set(figHandle, 'PaperPositionMode', 'auto');
    print(figHandle, outputPath, '-dpng', sprintf('-r%d', resolution));
end

%% ========== EXPORT SEGMENTATION VISUALIZATION FUNCTION ==========

function exportSegmentationVisualization(frame, imageName, angle, density, segData, cx, cy, r, pRef, mRef, exportFolder, varargin)
    % EXPORTSEGMENTATIONVISUALIZATION - Create and save individual analysis visualizations
    %
    % Usage: exportSegmentationVisualization(frame, imageName, angle, density, segData, cx, cy, r, pRef, mRef, exportFolder)
    %        exportSegmentationVisualization(..., hMin, hMax, sMin, vMin)
    %
    % Saves individual images:
    %   1. Green detection mask (binary)
    %   2. Segmentation with overlays (original + analysis)
    %   3. Summary panel (4-panel overview)
    
    % Handle optional HSV parameters
    if nargin >= 15
        hMin = varargin{1};
        hMax = varargin{2};
        sMin = varargin{3};
        vMin = varargin{4};
    else
        % Default values
        hMin = 0.15;
        hMax = 0.40;
        sMin = 0.10;
        vMin = 0.20;
    end
    
    % Extract segmentation data
    xBoundaryFiltered = segData.xBoundaryFiltered;
    yBoundaryFiltered = segData.yBoundaryFiltered;
    xBoundarySelected = segData.xBoundarySelected;
    yBoundarySelected = segData.yBoundarySelected;
    m = segData.m;
    
    % Use SCALED calibration parameters (stored during processing)
    % These match the frame dimensions after any resizing
    cx = segData.cx_scaled;
    cy = segData.cy_scaled;
    r = segData.r_scaled;
    mRef = segData.mRef_scaled;
    pRef = segData.pRef_scaled;
    if isfield(segData, 'segmentationDilationRadius')
        dilationRadius = segData.segmentationDilationRadius;
    else
        dilationRadius = 2;
    end
    if isfield(segData, 'segmentationClosingRadius')
        closingRadius = segData.segmentationClosingRadius;
    else
        closingRadius = 4;
    end
    
    [~, fileName, ~] = fileparts(imageName);
    
    % ========== SAVE 1: COLOR DETECTION MASK (Individual Full-Size) ==========
    fig1 = figure('Visible', 'off', 'Units', 'inches', 'Position', [0, 0, 10, 8]);
    
    % Recreate green mask for visualization
    Ihsv = rgb2hsv(frame);
    H = Ihsv(:,:,1);
    S = Ihsv(:,:,2);
    V = Ihsv(:,:,3);
    
    % Use centralized helper: Create green segmentation mask with optimized parameters
    % This ensures exported visualization matches the actual analysis
    greenMask = createColorSegmentationMask(frame, hMin, hMax, sMin, vMin, dilationRadius, closingRadius, 50);
    
    imshow(greenMask);
    colormap(gca, gray);
    title(['Color Detection Mask (HSV Segmentation) - ', fileName], 'FontSize', 14, 'FontWeight', 'bold');
    axis on;
    
    % Add colorbar and info
    text(0.02, 0.02, 'White = detected material | Black = background', ...
         'Units', 'normalized', 'FontSize', 10, 'Color', 'white', ...
         'BackgroundColor', 'black');
    
    maskPdfPath = fullfile(exportFolder, [fileName, '_01_color_mask.pdf']);
    maskPngPath = fullfile(exportFolder, [fileName, '_01_color_mask.png']);
    print(fig1, maskPdfPath, '-dpdf', '-r300');
    print(fig1, maskPngPath, '-dpng', '-r300');
    fprintf('  ✓ Color mask: %s\n', [fileName, '_01_color_mask']);
    close(fig1);
    
    % ========== SAVE 2: SEGMENTATION WITH OVERLAYS (Individual Full-Size) ==========
    fig2 = figure('Visible', 'off', 'Units', 'inches', 'Position', [0, 0, 10, 8]);
    
    imshow(frame);
    title(['Segmentation Analysis with Overlays - ', fileName], 'FontSize', 14, 'FontWeight', 'bold');
    hold on;
    
    % Plot detected boundary points (all filtered)
    if ~isempty(xBoundaryFiltered)
        plot(xBoundaryFiltered, yBoundaryFiltered, 'c.', 'MarkerSize', 8, 'DisplayName', 'Filtered boundary points');
    end
    
    % Plot selected subset (used for fitting)
    if ~isempty(xBoundarySelected)
        plot(xBoundarySelected, yBoundarySelected, 'm.', 'MarkerSize', 10, 'DisplayName', 'Selected points');
    end
    
    % Draw drum circle (using scaled coordinates from segData)
    theta = linspace(0, 2*pi, 100);
    circle_x = segData.cx_scaled + segData.r_scaled * cos(theta);
    circle_y = segData.cy_scaled + segData.r_scaled * sin(theta);
    plot(circle_x, circle_y, 'y--', 'LineWidth', 3, 'DisplayName', 'Drum circle');
    
    % Draw fitted line
    if ~isempty(xBoundarySelected)
        x_line = linspace(min(xBoundarySelected)-50, max(xBoundarySelected)+50, 100);
        y_line = m * x_line + (mean(yBoundarySelected) - m * mean(xBoundarySelected));
        plot(x_line, y_line, 'r-', 'LineWidth', 3, 'DisplayName', sprintf('Fitted line (=%.3f°)', angle));
    end
    
    % Draw reference line (using scaled coefficients from segData)
    x_ref = linspace(0, size(frame, 2), 100);
    y_ref = polyval(segData.pRef_scaled, x_ref);
    plot(x_ref, y_ref, 'w--', 'LineWidth', 3, 'DisplayName', 'Reference line');
    
    legend('Location', 'best', 'FontSize', 11, 'LineWidth', 1.5);
    hold off;
    axis on;
    
    segPdfPath = fullfile(exportFolder, [fileName, '_02_segmentation_overlay.pdf']);
    segPngPath = fullfile(exportFolder, [fileName, '_02_segmentation_overlay.png']);
    print(fig2, segPdfPath, '-dpdf', '-r300');
    print(fig2, segPngPath, '-dpng', '-r300');
    fprintf('  ✓ Segmentation: %s\n', [fileName, '_02_segmentation_overlay']);
    close(fig2);
    
    % ========== SAVE 3: SUMMARY PANEL (2x2 Overview) ==========
    fig3 = figure('Visible', 'off', 'Units', 'inches', 'Position', [0, 0, 12, 10]);
    
    % Panel 1: Original Image
    ax1 = subplot(2, 2, 1);
    imshow(frame);
    title('1. Original Image', 'FontSize', 12, 'FontWeight', 'bold');
    axis on;
    
    % Panel 2: Color Detection Mask
    ax2 = subplot(2, 2, 2);
    imshow(greenMask);
    colormap(ax2, gray);
    title('2. Color Detection Mask', 'FontSize', 12, 'FontWeight', 'bold');
    axis on;
    
    % Panel 3: Segmentation with Overlays
    ax3 = subplot(2, 2, 3);
    imshow(frame);
    title('3. Segmentation Analysis', 'FontSize', 12, 'FontWeight', 'bold');
    hold on;
    if ~isempty(xBoundaryFiltered)
        plot(xBoundaryFiltered, yBoundaryFiltered, 'c.', 'MarkerSize', 6, 'DisplayName', 'Filtered boundary');
    end
    if ~isempty(xBoundarySelected)
        plot(xBoundarySelected, yBoundarySelected, 'm.', 'MarkerSize', 8, 'DisplayName', 'Selected points');
    end
    plot(circle_x, circle_y, 'y--', 'LineWidth', 2, 'DisplayName', 'Drum circle');
    if ~isempty(xBoundarySelected)
        plot(x_line, y_line, 'r-', 'LineWidth', 2.5, 'DisplayName', 'Fitted line');
    end
    plot(x_ref, y_ref, 'w--', 'LineWidth', 2, 'DisplayName', 'Reference line');
    legend('Location', 'best', 'FontSize', 9);
    hold off;
    axis on;
    
    % Panel 4: Analysis Results
    ax4 = subplot(2, 2, 4);
    axis off;
    
    resultsText = sprintf([...
        'ANALYSIS RESULTS\n' ...
        '════════════════════════════════════\n\n' ...
        'Image: %s\n\n' ...
        'ANGLE OF REPOSE\n' ...
        '─────────────────────────────────────\n' ...
        'Measured angle: %.2f°\n' ...
        'Reference slope: %.6f\n' ...
        'Fitted slope: %.6f\n\n' ...
        'PACKING DENSITY\n' ...
        '─────────────────────────────────────\n' ...
        'Packing density: %.2f%%\n\n' ...
        'SEGMENTATION STATS\n' ...
        '─────────────────────────────────────\n' ...
        'Filtered boundary points: %d\n' ...
        'Selected points: %d\n' ...
        'Drum radius: %.0f px\n' ...
        'Drum center: (%.0f, %.0f) px\n'], ...
        imageName, angle, mRef, m, density, ...
        length(xBoundaryFiltered), length(xBoundarySelected), r, cx, cy);
    
    text(0.05, 0.95, resultsText, 'FontName', 'Monospaced', 'FontSize', 10, ...
         'VerticalAlignment', 'top', 'HorizontalAlignment', 'left');
    
    summaryPdfPath = fullfile(exportFolder, [fileName, '_03_summary_panel.pdf']);
    summaryPngPath = fullfile(exportFolder, [fileName, '_03_summary_panel.png']);
    print(fig3, summaryPdfPath, '-dpdf', '-r300');
    print(fig3, summaryPngPath, '-dpng', '-r300');
    fprintf('  ✓ Summary: %s\n', [fileName, '_03_summary_panel']);
    close(fig3);
end

%% ========== INITIAL FRAME DRUM OVERLAY EXPORT FUNCTION ==========

function overlayFile = exportInitialFrameDrumOverlay(frame, videoFile, runIdx, runCount, pRef, mRef, cx, cy, r, diameterTolerance, videoTimeWindowMode, analyzeLastSeconds, analysisStartSeconds, analysisDurationSeconds, startTime, endTime, videoDuration, exportFolder)
    % EXPORTINITIALFRAMEDRUMOVERLAY - Save first analyzed frame with shared calibration overlay

    [~, videoBaseName, ~] = fileparts(videoFile);
    safeBaseName = regexprep(videoBaseName, '[^A-Za-z0-9_-]', '_');
    overlayFile = fullfile(exportFolder, sprintf('%03d_of_%03d_%s_initial_frame_drum_overlay.png', runIdx, runCount, safeBaseName));

    fig = figure('Visible', 'off', 'Units', 'pixels', 'Position', [100, 100, 1400, 1000]);
    imshow(frame);
    hold on;

    theta = linspace(0, 2*pi, 300);
    circle_x = cx + r * cos(theta);
    circle_y = cy + r * sin(theta);
    plot(circle_x, circle_y, 'g-', 'LineWidth', 3, 'DisplayName', 'Drum circle');
    plot(cx, cy, 'go', 'MarkerSize', 12, 'LineWidth', 3, 'DisplayName', 'Drum center');

    usableRadius = max(r - diameterTolerance, 1);
    tolerance_x = cx + usableRadius * cos(theta);
    tolerance_y = cy + usableRadius * sin(theta);
    plot(tolerance_x, tolerance_y, 'c--', 'LineWidth', 2, 'DisplayName', 'Accepted boundary limit');

    x_ref = linspace(1, size(frame, 2), 200);
    y_ref = polyval(pRef, x_ref);
    plot(x_ref, y_ref, 'w--', 'LineWidth', 2.5, 'DisplayName', 'Reference line');

    title(sprintf('Initial Frame Drum Overlay: %s', videoBaseName), 'Interpreter', 'none', 'FontSize', 14, 'FontWeight', 'bold');
    windowDescription = describeVideoTimeWindow(videoTimeWindowMode, analyzeLastSeconds, analysisStartSeconds, analysisDurationSeconds);
    timeText = sprintf('Video %d/%d | analyzed window: %.3f s to %.3f s of %.3f s | %s', ...
                       runIdx, runCount, startTime, endTime, videoDuration, windowDescription);

    infoText = sprintf('%s\nCenter=(%.1f, %.1f) px | Diameter=%.1f px | diameter_tolerance=%.1f px | reference slope=%.6f', ...
                       timeText, cx, cy, 2*r, diameterTolerance, mRef);
    text(0.02, 0.98, infoText, 'Units', 'normalized', 'VerticalAlignment', 'top', ...
         'FontName', 'Monospaced', 'FontSize', 10, 'Color', 'white', ...
         'BackgroundColor', 'black', 'Margin', 6, 'Interpreter', 'none');

    legend('Location', 'best', 'TextColor', 'black');
    hold off;

    print(fig, overlayFile, '-dpng', '-r200');
    close(fig);
end

%% ========== SCALING VALIDATION FUNCTION ==========

function validateScalingConsistency(frame, mRef, cx, cy, r, minArea, smoothWindow, drumTolerance, yLower, yUpper, varargin)
    % VALIDATESCALINGCONSISTENCY - Compare angle measurements at different image scales
    %
    % Usage: validateScalingConsistency(frame, mRef, cx, cy, r, minArea, smoothWindow, drumTolerance, yLower, yUpper)
    %        validateScalingConsistency(..., hMin, hMax, sMin, vMin)
    %
    % Tests if scaling affects angle measurement by processing the same image
    % at multiple scales and comparing results.
    
    % Handle optional HSV parameters
    if nargin >= 14
        hMin = varargin{1};
        hMax = varargin{2};
        sMin = varargin{3};
        vMin = varargin{4};
    else
        % Default values
        hMin = 0.15;
        hMax = 0.40;
        sMin = 0.10;
        vMin = 0.20;
    end

    if numel(varargin) >= 5
        edgeThreshold = varargin{5};
    else
        edgeThreshold = 0.10;
    end

    if numel(varargin) >= 7
        dilationRadius = varargin{6};
        closingRadius = varargin{7};
    else
        dilationRadius = 2;
        closingRadius = 4;
    end
    
    fprintf('\n╔════════════════════════════════════════════╗\n');
    fprintf('║   SCALING CONSISTENCY VALIDATION TEST     ║\n');
    fprintf('╚════════════════════════════════════════════╝\n\n');
    
    % Test scales: 100%, 75%, 50%, 25% of original
    testScales = [1.0, 0.75, 0.50, 0.25];
    measuredAngles = [];
    measuredDensities = [];
    
    fprintf('Scale   Image Size      Angle (°)  Density (%)  Time (s)\n');
    fprintf('────────────────────────────────────────────────────────\n');
    
    for scaleIdx = 1:length(testScales)
        scaleFactor = testScales(scaleIdx);
        
        tic;
        
        % Resize image
        if scaleFactor < 1.0
            newWidth = round(size(frame, 2) * scaleFactor);
            newHeight = round(size(frame, 1) * scaleFactor);
            frameScaled = imresize(frame, [newHeight, newWidth], 'bilinear');
        else
            frameScaled = frame;
        end
        
        % Scale calibration parameters
        cx_s = cx * scaleFactor;
        cy_s = cy * scaleFactor;
        r_s = r * scaleFactor;
        mRef_s = mRef;
        drumTolerance_s = drumTolerance * scaleFactor;
        
        % Calculate angle
        [theta_s, ~, ~, ~, ~, ~] = calculateFrameAngle(frameScaled, mRef_s, cx_s, cy_s, r_s, ...
                    minArea, smoothWindow, drumTolerance_s, yLower, yUpper, ...
                    hMin, hMax, sMin, vMin, edgeThreshold, dilationRadius, closingRadius);
        
        % Calculate density
        density_s = calculateDensity(frameScaled, cx_s, cy_s, r_s, hMin, hMax, sMin, vMin, minArea, dilationRadius, closingRadius);
        
        iterTime = toc;
        
        measuredAngles(scaleIdx) = theta_s;
        measuredDensities(scaleIdx) = density_s;
        
        fprintf('%d%%      %d×%d           %.2f°      %.2f%%        %.3f\n', ...
                round(100*scaleFactor), size(frameScaled, 2), size(frameScaled, 1), theta_s, density_s, iterTime);
    end
    
    % Calculate statistics
    fprintf('\n────────────────────────────────────────────────────────\n');
    fprintf('\nANALYSIS OF SCALE EFFECTS:\n');
    fprintf('─────────────────────────────────────────────────────────\n\n');
    
    angleAtFullScale = measuredAngles(1);
    angleVariation = measuredAngles - angleAtFullScale;
    angleStdDev = std(angleVariation);
    angleMaxDiff = max(abs(angleVariation));
    
    densityAtFullScale = measuredDensities(1);
    densityVariation = measuredDensities - densityAtFullScale;
    densityStdDev = std(densityVariation);
    densityMaxDiff = max(abs(densityVariation));
    
    fprintf('ANGLE OF REPOSE (reference: 100%% scale = %.2f°):\n', angleAtFullScale);
    fprintf('  Max deviation from 100%%: %.4f° (%+.2f%%)\n', angleMaxDiff, 100*angleMaxDiff/angleAtFullScale);
    fprintf('  Std dev of deviations:    %.4f°\n', angleStdDev);
    
    fprintf('\nPACKING DENSITY (reference: 100%% scale = %.2f%%):\n', densityAtFullScale);
    fprintf('  Max deviation from 100%% : %.4f%% (%+.2f%%)\n', densityMaxDiff, 100*densityMaxDiff/densityAtFullScale);
    fprintf('  Std dev of deviations:     %.4f%%\n', densityStdDev);
    
    fprintf('\n────────────────────────────────────────────────────────\n');
    
    % Assessment
    if angleMaxDiff < 0.5
        fprintf('\n✓ PASSED: Angle measurements are CONSISTENT across scales.\n');
        fprintf('  Scaling has MINIMAL effect on angle analysis.\n');
    elseif angleMaxDiff < 1.0
        fprintf('\n⚠ MARGINAL: Angle measurements show minor variation.\n');
        fprintf('  Scaling has SMALL effect on angle analysis.\n');
    else
        fprintf('\n✗ WARNING: Angle measurements VARY significantly across scales!\n');
        fprintf('  Scaling may SIGNIFICANTLY affect angle analysis.\n');
        fprintf('  Consider disabling image resizing (set maxImageWidth = 0).\n');
    end
    
    fprintf('\n────────────────────────────────────────────────────────\n\n');
end
