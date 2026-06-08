%% VALIDATION ANGLE ANALYSIS - ROTATING DRUM BOX ROI (BATCH PROCESSING)
% Batch video processing script for validation experiments: configure the
% first video once, then reuse that configuration for every video found
% under the main batch folder.
%
% WORKFLOW:
%   1. Set videoFolder to the main folder containing experiment folders
%   2. Run THIS SCRIPT and configure the first video when prompted
%   3. Define the drum circle, then segment the blue plane that defines the
%      validation box length
%   4. The validation box height is set to the calibrated drum radius and is
%      extended from the blue plane toward the drum center
%   5. Calibrate material segmentation, then measure the material surface
%      angle inside the validation box
%   6. Results are saved beside each source video as CSV/MAT files
%
% ADVANTAGES OF THIS SPLIT:
%   • Process images ONCE, iterate on analysis MANY times (fast!)
%   • Change plots/statistics without reprocessing
%   • Review raw data in Excel (.csv file)
%   • Separate concerns: processing vs visualization

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
videoFile = '/Users/andersriis/Desktop/Validation_Data/Videos_Experiment/Flower/Flower_Experiment_5.MOV';
videoFolder = ['/Users/andersriis/Desktop/Validation_Data/3. Calibrated_data/Video_Sim_Calibrated/Flower'];
videoExtensions = {'*.mp4', '*.mov', '*.avi', '*.m4v'};
recursiveVideoSearch = true;
saveResultsNextToSourceVideo = true;
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
diameter_tolerance = 60;  % Accepted edge points must be at least this many pixels inside the drum radius
diameterTolerance = diameter_tolerance;
drumTolerance = diameterTolerance;  % Backward-compatible name used in saved result parameters
edgeThreshold = 0.10;      % Canny edge threshold for boundary detection
segmentationDilationRadius = 4;
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
exportAlignedValidationFrameImages = true;  % Save each accepted aligned validation frame with overlays
exportSlipValidationFrameImages = true;  % Save the first frame where material has slipped out of the validation box
alignedValidationFrameFolder = 'aligned_validation_instances';
exportAlignedValidationSummaryCsv = true;  % Save rotation/timestamp/angle CSV for accepted aligned instances
alignedValidationSummaryCsvSuffix = '_aligned_rotation_summary';
combinedAlignedValidationCsvFileName = 'combined_aligned_validation_angles.csv';
combinedAlignedValidationWorkbookFileName = 'combined_aligned_validation_by_subfolder.xlsx';
exportCombinedSubfolderWorkbook = true;  % Save one combined Excel layout with one row per subfolder
exportCalibrationImages = true;     % Save accepted color-calibration window, panels, and threshold values
calibrationExportFolder = 'calibration_export';
validationBoxCalibrationExportFolder = 'validation_box_calibration_export';

%% -------- VALIDATION BOX PLANE CALIBRATION --------
% The blue plane defines the horizontal length of the validation box. The
% box height is one calibrated drum radius and extends toward the drum center.
validationPlaneColorChoice = 'b';
validationPlaneMinArea = 500;
validationPlaneEdgeThreshold = 0.08;
validationPlaneDilationRadius = 4;
validationPlaneClosingRadius = 3;
validationBoxTolerance = 10;  % Inward pixel tolerance from validation-box edges for material edge fitting
analyzeOnlyAlignedValidationBox = true;  % Analyze once when the blue plane is horizontal/right-side per rotation
validationBoxAlignmentToleranceDegrees = 1;  % Blue-plane angle must be this close to the reference line
validationBoxRightSideMinOffsetFraction = 0.00;  % Plane center must be at least this drum-radius fraction right of center
validationBoxMinFramesBetweenAnalyses = 5;  % Prevent duplicate picks in the same alignment event
validationAlignmentSkipLogFrequency = 50;  % Print every N skipped frames while waiting for alignment
extendAlignedValidationBoxForAnalysis = true;  % Extend only the accepted aligned-frame analysis box
alignedValidationBoxLengthExtensionFraction = 1.0;  % Extra length toward opposite drum side, as fraction of drum radius
enableSlipAngleTracking = true;  % After each aligned-frame angle, find when material has slipped out of the box
slipMinFramesAfterAlignment = 1;  % Start checking this many frames after the accepted alignment frame
slipSkipFramesAfterDetection = 210;  % Skip this many frames after a slip angle is detected
slipMaterialInsideMaxPixels = 50;  % Allow this many segmented material pixels inside the box at slip
slipMaterialInsideMaxFraction = 0.01;  % Or this fraction of total material inside the box at slip
showAnalyzedFramePreview = false;  % Show accepted analyzed frames with the detected material line
pauseOnAnalyzedFramePreview = true;  % When previewing, wait for key/click before continuing

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
combinedAlignmentSourceFiles = {};
combinedAlignmentFrameNames = {};
combinedAlignmentRotations = [];
combinedAlignmentTimestamps = [];
combinedAlignmentFrameIndices = [];
combinedRotationFrameCounts = [];
combinedRotationRpms = [];
combinedAlignmentAngles = [];
combinedSlipDetected = [];
combinedSlipFrameNames = {};
combinedSlipTimestamps = [];
combinedSlipAngles = [];
combinedSlipMaterialPixelsInBox = [];
combinedSlipMaterialFractionInBox = [];
combinedSlipExportDirs = {};
combinedLayoutSubfolderLabels = {};
combinedLayoutPlaneAngles = {};
combinedLayoutSlipAngles = {};

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
        if strcmpi(videoTimeWindowMode, 'full')
            fprintf('Full-video mode: counting readable frames in this loaded video...\n');
            totalFrames = countReadableVideoFrames(videoObj);
        else
            totalFrames = max(1, floor(videoObj.Duration * videoObj.FrameRate));
        end
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
        if strcmpi(videoTimeWindowMode, 'full')
            startFrame = 1;
            endFrame = totalFrames;
            fprintf('Full-video mode: analyzing every frame from 1 to %d for this video.\n', totalFrames);
        else
            endFrame = min(totalFrames, max(1, ceil(endTime * videoObj.FrameRate)));
            startFrame = min(endFrame, max(1, floor(startTime * videoObj.FrameRate) + 1));
        end
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

%% -------- VALIDATION BOX DEFINITION FROM BLUE PLANE --------
fprintf('\n--- VALIDATION BOX BLUE PLANE CALIBRATION ---\n');
[hMin_plane_preset, hMax_plane_preset, sMin_plane_preset, vMin_plane_preset, planeColorLabel] = getColorPreset(validationPlaneColorChoice);
fprintf('Using %s preset for validation plane: H=[%.3f, %.3f], S>%.3f, V>%.3f\n', ...
        planeColorLabel, hMin_plane_preset, hMax_plane_preset, sMin_plane_preset, vMin_plane_preset);

validationBoxExportDir = '';
validationBoxSourceLabel = 'validation_box_frame';
if exportCalibrationImages
    if isVideoInput && saveResultsNextToSourceVideo
        validationBoxParentFolder = currentVideoFolder;
    else
        validationBoxParentFolder = resultsRootFolder;
    end
    if ~isfolder(validationBoxParentFolder)
        mkdir(validationBoxParentFolder);
        fprintf('Created results root folder: %s\n', validationBoxParentFolder);
    end
    validationBoxExportDir = fullfile(validationBoxParentFolder, validationBoxCalibrationExportFolder);
    if ~isfolder(validationBoxExportDir)
        mkdir(validationBoxExportDir);
        fprintf('Created validation-box calibration export folder: %s\n', validationBoxExportDir);
    end

    if isVideoInput
        [~, validationBoxSourceLabel, ~] = fileparts(currentVideoFile);
    else
        [~, validationBoxSourceLabel, ~] = fileparts(imageFiles{1});
    end
end

[validationBox, hMin_plane, hMax_plane, sMin_plane, vMin_plane, ...
    validationPlaneEdgeThreshold, validationPlaneDilationRadius, validationPlaneClosingRadius, validationBoxAccepted] = ...
    improvedValidationBoxCalibrationTool(I_first, cx, cy, r, validationPlaneMinArea, ...
                                        hMin_plane_preset, hMax_plane_preset, sMin_plane_preset, vMin_plane_preset, ...
                                        validationPlaneEdgeThreshold, validationPlaneDilationRadius, validationPlaneClosingRadius, ...
                                        validationBoxExportDir, validationBoxSourceLabel);

if ~validationBoxAccepted
    error('Validation box calibration was cancelled. The validation analysis requires a defined box.');
end

fprintf('Validation box accepted: width %.1f px, height %.1f px, area %.0f px^2\n', ...
        validationBox.width, validationBox.height, validationBox.areaPixels);
fprintf('Box x range: [%.1f, %.1f], y range: [%.1f, %.1f]\n', ...
        validationBox.xMin, validationBox.xMax, validationBox.yMin, validationBox.yMax);
fprintf('Blue plane angle: %.2f deg relative to image horizontal\n', validationBox.angleDegrees);

%% -------- COLOR PRESET SELECTION --------
fprintf('\n--- BRICK COLOR PRESET ---\n');
fprintf('Select brick color: g = green, y = yellow, r = red, b = blue\n');
colorChoice = input('Color choice (g/y/r/b, default = g): ', 's');
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

    [hMin_cal, hMax_cal, sMin_cal, vMin_cal, edgeThreshold_cal, dilationRadius_cal, closingRadius_cal, diameterTolerance_cal, validationBoxTolerance_cal, calibrationAccepted] = ...
        improvedColorCalibrationTool(I_first, mRef, cx, cy, r, minArea, smoothWindow, diameterTolerance, yLower, yUpper, ...
                                     hMin_preset, hMax_preset, sMin_preset, vMin_preset, colorLabel, edgeThreshold, ...
                                     segmentationDilationRadius, segmentationClosingRadius, ...
                                     calibrationExportDir, calibrationSourceLabel, validationBox, validationBoxTolerance);
    
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
        diameterTolerance = diameterTolerance_cal;
        drumTolerance = diameterTolerance;
        validationBoxTolerance = validationBoxTolerance_cal;
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
                               segmentationDilationRadius, segmentationClosingRadius, validationBox, validationBoxTolerance);
    
    fprintf('\nValidation complete. Check results above.\n');
    fprintf('If angle differences are < 0.5°, scaling has minimal impact.\n\n');
end

calibrationComplete = true;
else
    fprintf('\n--- REUSING CALIBRATION FROM FIRST VIDEO ---\n');
    fprintf('Reference slope: %.6f\n', mRef);
    fprintf('Drum center: (%.1f, %.1f), radius: %.1f px, diameter: %.1f px\n', cx, cy, r, 2*r);
    fprintf('Diameter/drum tolerance: %.1f px\n', diameterTolerance);
    fprintf('Validation box: width %.1f px, height %.1f px, x=[%.1f, %.1f], y=[%.1f, %.1f]\n', ...
            validationBox.width, validationBox.height, validationBox.xMin, validationBox.xMax, validationBox.yMin, validationBox.yMax);
    fprintf('Validation box tolerance: %.1f px\n', validationBoxTolerance);
    fprintf('Validation plane calibration: H=[%.3f, %.3f], S>%.3f, V>%.3f\n', ...
            hMin_plane, hMax_plane, sMin_plane, vMin_plane);
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
    videoBaseName = 'image_sequence';
end

alignedValidationFrameExportDir = '';
if exportAlignedValidationFrameImages || exportSlipValidationFrameImages
    if isVideoMode
        alignedValidationFrameExportDir = fullfile(resultsFolder, [videoBaseName, '_', alignedValidationFrameFolder]);
    else
        alignedValidationFrameExportDir = fullfile(resultsFolder, alignedValidationFrameFolder);
    end
    if ~isfolder(alignedValidationFrameExportDir)
        mkdir(alignedValidationFrameExportDir);
        fprintf('Created aligned validation frame export folder: %s\n', alignedValidationFrameExportDir);
    end
end

if isVideoMode && exportInitialFrameOverlays
    initialOverlayDir = fullfile(resultsFolder, initialFrameOverlayFolder);
    if ~isfolder(initialOverlayDir)
        mkdir(initialOverlayDir);
        fprintf('Created initial-frame overlay folder: %s\n', initialOverlayDir);
    end
    overlayFile = exportInitialFrameDrumOverlay(currentInitialFrame, currentVideoFile, runIdx, runCount, ...
                                               pRef, mRef, cx, cy, r, diameterTolerance, ...
                                               validationBox, ...
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
rotationFrameIndices = [];  % Accepted alignment frame number for each rotation
slipDetected = [];
slipFrameNames = {};
slipFrameTimes = [];
slipAngles = [];
slipMaterialPixelsInBox = [];
slipMaterialFractionInBox = [];
slipExportDirs = {};
successCount = 0;
failCount = 0;
abortEarly = false;
skippedAlignmentCount = 0;
alignmentCandidateCount = 0;
validationAlignmentWindowActive = false;
lastAcceptedAlignmentFrame = -Inf;
slipTrackingActive = false;
pendingSlipRotationIndex = NaN;
pendingSlipAlignmentFrame = -Inf;
slipPostDetectionSkipUntilFrame = -Inf;
slipPostDetectionSkippedCount = 0;

for i = 1:numImagesToAnalyze
    if isVideoMode
        frameIdx = frameIndices(i);
        frameTime = (frameIdx - 1) / videoObj.FrameRate;
        fullImageName = sprintf('frame_%06d_t%.3fs', frameIdx, frameTime);
    else
        [~, imageName, ext] = fileparts(imageFiles{i});
        fullImageName = [imageName, ext];
        frameTime = NaN;
    end
    iterationTic = tic;

    if isVideoMode && enableSlipAngleTracking && i <= slipPostDetectionSkipUntilFrame
        slipPostDetectionSkippedCount = slipPostDetectionSkippedCount + 1;
        validationAlignmentWindowActive = false;
        iterTime = toc(iterationTic);
        processingTimes(end+1) = iterTime;
        framesRemainingInSlipSkip = slipPostDetectionSkipUntilFrame - i + 1;
        if validationAlignmentSkipLogFrequency > 0 && ...
           (slipPostDetectionSkippedCount == 1 || framesRemainingInSlipSkip == 1 || ...
            mod(slipPostDetectionSkippedCount, validationAlignmentSkipLogFrequency) == 0)
            fprintf('Image %3d/%d: %-40s  SKIPPED after slip detection (%d frames remaining, %.2fs)\n', ...
                    i, numImagesToAnalyze, fullImageName, framesRemainingInSlipSkip, iterTime);
        end
        if clearMemory && mod(i, 20) == 0
            pause(0.1);
        end
        continue;
    end
    
    try
        % Read image
        if isVideoMode
            frame = read(videoObj, frameIdx);
        else
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
        validationBox_scaled = scaleValidationBox(validationBox, scaleFactor);
        validationBoxTolerance_scaled = validationBoxTolerance * scaleFactor;
        activeValidationBox_scaled = validationBox_scaled;
        detectedValidationBox_scaled = validationBox_scaled;
        validationBoxExtendedForAnalysis = false;
        validationBoxLengthExtension_scaled = 0;
        alignmentInfo = struct('enabled', false, 'isAligned', true, 'reason', 'not gated', ...
                               'angleDifferenceDegrees', NaN, 'planeAngleDegrees', NaN, ...
                               'planeCenterX', NaN, 'planeCenterY', NaN, 'isRightSide', true);

        if analyzeOnlyAlignedValidationBox
            validationPlaneMinArea_scaled = max(20, round(validationPlaneMinArea * scaleFactor^2));
            [trackedValidationBox, ~, ~, ~, ~] = deriveValidationBoxFromPlane(frame, cx_scaled, cy_scaled, r_scaled, validationPlaneMinArea_scaled, ...
                hMin_plane, hMax_plane, sMin_plane, vMin_plane, validationPlaneEdgeThreshold, ...
                validationPlaneDilationRadius, validationPlaneClosingRadius);
            [isAlignedForAnalysis, alignmentInfo] = isValidationBoxAlignedForAnalysis(trackedValidationBox, mRef_scaled, cx_scaled, r_scaled, ...
                validationBoxAlignmentToleranceDegrees, validationBoxRightSideMinOffsetFraction);

            if isAlignedForAnalysis
                alignmentCandidateCount = alignmentCandidateCount + 1;
            end

            hasFrameGap = (i - lastAcceptedAlignmentFrame) >= validationBoxMinFramesBetweenAnalyses;
            shouldAnalyzeAlignedFrame = isAlignedForAnalysis && ~validationAlignmentWindowActive && hasFrameGap;

            if enableSlipAngleTracking && slipTrackingActive && ~shouldAnalyzeAlignedFrame && ...
               (i - pendingSlipAlignmentFrame) >= slipMinFramesAfterAlignment && ~isempty(trackedValidationBox)
                slipMaterialInsideMaxPixels_scaled = max(0, round(slipMaterialInsideMaxPixels * scaleFactor^2));
                [hasSlipped, slipInfo] = detectMaterialSlippedFromValidationBox(frame, trackedValidationBox, validationBoxTolerance_scaled, ...
                    hMin_custom, hMax_custom, sMin_custom, vMin_custom, minArea, ...
                    segmentationDilationRadius, segmentationClosingRadius, ...
                    cx_scaled, cy_scaled, r_scaled, drumTolerance_scaled, ...
                    slipMaterialInsideMaxPixels_scaled, slipMaterialInsideMaxFraction);

                if hasSlipped
                    referenceAngleDegrees = atan(mRef_scaled) * 180/pi;
                    slipAngleDegrees = lineAngleDifferenceDegrees(trackedValidationBox.angleDegrees, referenceAngleDegrees);
                    slipInfo.rotation = pendingSlipRotationIndex;
                    slipInfo.frameName = fullImageName;
                    slipInfo.timestampSeconds = frameTime;
                    slipInfo.slipAngleDegrees = slipAngleDegrees;
                    slipInfo.planeAngleDegrees = trackedValidationBox.angleDegrees;
                    slipInfo.referenceAngleDegrees = referenceAngleDegrees;
                    slipInfo.validationBox_scaled = trackedValidationBox;
                    slipInfo.validationBoxTolerance_scaled = validationBoxTolerance_scaled;
                    slipInfo.cx_scaled = cx_scaled;
                    slipInfo.cy_scaled = cy_scaled;
                    slipInfo.r_scaled = r_scaled;
                    slipInfo.drumTolerance_scaled = drumTolerance_scaled;
                    slipInfo.pRef_scaled = [pRef(1), pRef(2) * scaleFactor];

                    if ~isnan(pendingSlipRotationIndex) && pendingSlipRotationIndex >= 1 && pendingSlipRotationIndex <= numel(slipAngles)
                        slipDetected(pendingSlipRotationIndex) = true;
                        slipFrameNames{pendingSlipRotationIndex} = fullImageName;
                        slipFrameTimes(pendingSlipRotationIndex) = frameTime;
                        slipAngles(pendingSlipRotationIndex) = slipAngleDegrees;
                        slipMaterialPixelsInBox(pendingSlipRotationIndex) = slipInfo.materialPixelsInBox;
                        slipMaterialFractionInBox(pendingSlipRotationIndex) = slipInfo.materialFractionInBox;

                        if exportSlipValidationFrameImages
                            slipExportDir = exportSlipValidationInstance(frame, fullImageName, slipInfo, ...
                                alignedValidationFrameExportDir, pendingSlipRotationIndex);
                            slipExportDirs{pendingSlipRotationIndex} = slipExportDir;
                            fprintf('  Saved slip-angle overlay: %s\n', slipExportDir);
                        end
                    end

                    fprintf('Image %3d/%d: %-40s  SLIP angle = %.2f deg  material in box = %d px (%.4f)\n', ...
                            i, numImagesToAnalyze, fullImageName, slipAngleDegrees, ...
                            slipInfo.materialPixelsInBox, slipInfo.materialFractionInBox);
                    slipTrackingActive = false;
                    pendingSlipRotationIndex = NaN;
                    pendingSlipAlignmentFrame = -Inf;
                    if slipSkipFramesAfterDetection > 0
                        slipPostDetectionSkipUntilFrame = max(slipPostDetectionSkipUntilFrame, i + slipSkipFramesAfterDetection);
                        fprintf('  Skipping next %d frames after slip detection.\n', slipSkipFramesAfterDetection);
                    end
                end
            end

            if ~shouldAnalyzeAlignedFrame
                skippedAlignmentCount = skippedAlignmentCount + 1;
                validationAlignmentWindowActive = isAlignedForAnalysis;
                iterTime = toc(iterationTic);
                processingTimes(end+1) = iterTime;
                if validationAlignmentSkipLogFrequency > 0 && ...
                   (skippedAlignmentCount == 1 || mod(skippedAlignmentCount, validationAlignmentSkipLogFrequency) == 0)
                    fprintf('Image %3d/%d: %-40s  SKIPPED alignment gate (%s, %.2fs)\n', ...
                            i, numImagesToAnalyze, fullImageName, alignmentInfo.reason, iterTime);
                end
                if clearMemory && mod(i, 20) == 0
                    pause(0.1);
                end
                continue;
            end

            validationAlignmentWindowActive = true;
            lastAcceptedAlignmentFrame = i;
            detectedValidationBox_scaled = trackedValidationBox;
            activeValidationBox_scaled = trackedValidationBox;
            if extendAlignedValidationBoxForAnalysis && alignedValidationBoxLengthExtensionFraction > 0
                validationBoxLengthExtension_scaled = alignedValidationBoxLengthExtensionFraction * r_scaled;
                activeValidationBox_scaled = extendValidationBoxTowardOppositeDrumSide(...
                    trackedValidationBox, cx_scaled, cy_scaled, r_scaled, validationBoxLengthExtension_scaled);
                validationBoxExtendedForAnalysis = true;
            end
        end
        
        % Calculate angle and segmentation inside the calibrated validation box
        [theta, xBoundaryFiltered, yBoundaryFiltered, xBoundarySelected, yBoundarySelected, m] = ...
            calculateFrameAngleInValidationBox(frame, mRef_scaled, activeValidationBox_scaled, minArea, smoothWindow, yLower, yUpper, ...
                                               hMin_custom, hMax_custom, sMin_custom, vMin_custom, edgeThreshold, ...
                                               segmentationDilationRadius, segmentationClosingRadius, ...
                                               validationBoxTolerance_scaled, cx_scaled, cy_scaled, r_scaled, drumTolerance_scaled);

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
            % Calculate packing density inside the validation box
            density = calculateBoxDensity(frame, activeValidationBox_scaled, hMin_custom, hMax_custom, sMin_custom, vMin_custom, ...
                                          minArea, segmentationDilationRadius, segmentationClosingRadius);
            
            angles(end+1) = theta;
            densities(end+1) = density;
            imageNames{end+1} = fullImageName;
            scaleFactors(end+1) = scaleFactor;
            if isVideoMode
                frameTimes(end+1) = frameTime;
                rotationFrameIndices(end+1) = frameIdx;
            else
                rotationFrameIndices(end+1) = NaN;
            end
            slipDetected(end+1) = false;
            slipFrameNames{end+1} = '';
            slipFrameTimes(end+1) = NaN;
            slipAngles(end+1) = NaN;
            slipMaterialPixelsInBox(end+1) = NaN;
            slipMaterialFractionInBox(end+1) = NaN;
            slipExportDirs{end+1} = '';
            
            % ONLY store frames if explicitly requested (saves memory)
            % Also store if exporting segmentation images
            if storeFrames || exportSegmentationImages
                frames{end+1} = frame;
            end
            
            % Store segmentation data (including scaled calibration for correct visualization)
            segData = struct(...
                'xBoundaryFiltered', xBoundaryFiltered, ...
                'yBoundaryFiltered', yBoundaryFiltered, ...
                'xBoundarySelected', xBoundarySelected, ...
                'yBoundarySelected', yBoundarySelected, ...
                'm', m, ...
                'density', density, ...
                'cx_scaled', cx_scaled, ...      % Scaled drum center
                'cy_scaled', cy_scaled, ...      % Scaled drum center
                'r_scaled', r_scaled, ...        % Scaled drum radius
                'validationBox_scaled', activeValidationBox_scaled, ...
                'detectedValidationBox_scaled', detectedValidationBox_scaled, ...
                'validationBoxExtendedForAnalysis', validationBoxExtendedForAnalysis, ...
                'validationBoxLengthExtension_scaled', validationBoxLengthExtension_scaled, ...
                'validationBoxTolerance_scaled', validationBoxTolerance_scaled, ...
                'validationBoxAlignmentInfo', alignmentInfo, ...
                'drumTolerance_scaled', drumTolerance_scaled, ...
                'mRef_scaled', mRef_scaled, ... % Scaled reference line slope
                'segmentationDilationRadius', segmentationDilationRadius, ...
                'segmentationClosingRadius', segmentationClosingRadius, ...
                'pRef_scaled', [pRef(1), pRef(2) * scaleFactor]); % Scaled reference line coefficients
            segmentationData{end+1} = segData;
            
            successCount = successCount + 1;
            if enableSlipAngleTracking && analyzeOnlyAlignedValidationBox
                slipTrackingActive = true;
                pendingSlipRotationIndex = numel(angles);
                pendingSlipAlignmentFrame = i;
            end
            iterTime = toc(iterationTic);
            processingTimes(end+1) = iterTime;
            fprintf('Image %3d/%d: %-40s  Angle = %.2f°  Box density = %.1f%%  (%.2fs)\n', ...
                    i, numImagesToAnalyze, fullImageName, theta, density, iterTime);

            if exportAlignedValidationFrameImages
                instanceExportDir = exportAlignedValidationInstance(frame, fullImageName, theta, density, segData, ...
                    alignedValidationFrameExportDir, successCount, iterTime);
                fprintf('  Saved aligned validation overlay: %s\n', instanceExportDir);
            end

            if showAnalyzedFramePreview
                showValidationAnalysisPreview(frame, fullImageName, theta, density, segData, pauseOnAnalyzedFramePreview);
            end
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
                fprintf('Box density: Mean=%.1f%%, Std=%.1f%%, Range=[%.1f%%, %.1f%%]\n', ...
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
        if numel(keepMask) == numel(slipDetected)
            slipDetected = slipDetected(keepMask);
            slipFrameNames = slipFrameNames(keepMask);
            slipFrameTimes = slipFrameTimes(keepMask);
            slipAngles = slipAngles(keepMask);
            slipMaterialPixelsInBox = slipMaterialPixelsInBox(keepMask);
            slipMaterialFractionInBox = slipMaterialFractionInBox(keepMask);
            slipExportDirs = slipExportDirs(keepMask);
        end
        if isVideoMode && ~isempty(frameTimes) && numel(keepMask) == numel(frameTimes)
            frameTimes = frameTimes(keepMask);
        end
        if numel(keepMask) == numel(rotationFrameIndices)
            rotationFrameIndices = rotationFrameIndices(keepMask);
        end
    end
elseif successCount > 0 && ~shouldRunInteractiveReview
    fprintf('\n--- SKIPPING INTERACTIVE REVIEW FOR BATCH RUN ---\n');
    fprintf('Measurements will be saved automatically so the next video can start.\n');
end

if numel(rotationFrameIndices) ~= numel(angles)
    rotationFrameIndices = nan(1, numel(angles));
end
if isVideoMode
    currentFrameRate = videoObj.FrameRate;
else
    currentFrameRate = NaN;
end
[rotationFrameCounts, rotationRpms] = calculateRotationRpmFromFrameIndices(rotationFrameIndices, currentFrameRate);

%% -------- FINAL RESULTS (AFTER INTERACTIVE REVIEW) --------
fprintf('\n----- FINAL ANALYSIS RESULTS -----\n');

if abortEarly
    fprintf('Analysis type: PARTIAL (stopped early by user)\n');
else
    fprintf('Analysis type: COMPLETE\n');
end

fprintf('Images processed: %d\n', successCount + failCount + skippedAlignmentCount + slipPostDetectionSkippedCount);
fprintf('Successful detections: %d\n', successCount); 
fprintf('Failed detections: %d\n', failCount);
if analyzeOnlyAlignedValidationBox
    fprintf('Skipped by validation alignment gate: %d\n', skippedAlignmentCount);
    fprintf('Aligned right-side candidate frames: %d\n', alignmentCandidateCount);
end
if enableSlipAngleTracking
    fprintf('Slip events detected: %d\n', sum(logical(slipDetected)));
    fprintf('Skipped after slip detection: %d\n', slipPostDetectionSkippedCount);
end
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
    
    fprintf('\nFinal Box Density Statistics:\n');
    fprintf('  Average box density: %.2f %%\n', avgDensity);
    fprintf('  Std deviation:       %.2f %%\n', stdDensity);
    fprintf('  Min box density:     %.2f %%\n', minDensity);
    fprintf('  Max box density:     %.2f %%\n', maxDensity);

    validRotationRpms = rotationRpms(isfinite(rotationRpms));
    if isVideoMode && ~isempty(validRotationRpms)
        fprintf('\nFinal Rotation Speed Statistics:\n');
        fprintf('  Average RPM: %.2f\n', mean(validRotationRpms));
        fprintf('  Std RPM:     %.2f\n', std(validRotationRpms));
        fprintf('  Min RPM:     %.2f\n', min(validRotationRpms));
        fprintf('  Max RPM:     %.2f\n', max(validRotationRpms));
    end
    
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
fprintf('Next step: open the saved validation CSV/MAT results for plots and detailed statistics.\n\n');

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

    numMeasurements = numel(angles);
    if numel(slipDetected) ~= numMeasurements
        slipDetected = false(1, numMeasurements);
        slipFrameNames = repmat({''}, 1, numMeasurements);
        slipFrameTimes = nan(1, numMeasurements);
        slipAngles = nan(1, numMeasurements);
        slipMaterialPixelsInBox = nan(1, numMeasurements);
        slipMaterialFractionInBox = nan(1, numMeasurements);
        slipExportDirs = repmat({''}, 1, numMeasurements);
    end
    slipDetectedValues = logical(slipDetected(:));
    slipFrameNameValues = slipFrameNames(:);
    slipTimestampSeconds = slipFrameTimes(:);
    slipAngleValues = slipAngles(:);
    slipMaterialPixelValues = slipMaterialPixelsInBox(:);
    slipMaterialFractionValues = slipMaterialFractionInBox(:);
    slipExportDirValues = slipExportDirs(:);
    rotationFrameIndexValues = rotationFrameIndices(:);
    rotationFrameCountValues = rotationFrameCounts(:);
    rotationRpmValues = rotationRpms(:);
    
    % Create results table for CSV
    if isVideoMode && ~isempty(frameTimes)
        resultsTable = table(imageNames', frameTimes', rotationFrameIndexValues, rotationFrameCountValues, rotationRpmValues, ...
                            angles', densities', scaleFactors', ...
                            slipDetectedValues, slipFrameNameValues, slipTimestampSeconds, slipAngleValues, ...
                            slipMaterialPixelValues, slipMaterialFractionValues, slipExportDirValues, ...
                            'VariableNames', {'FrameName', 'Time_seconds', 'AlignmentFrame', 'RotationFrameCount', 'Rotation_RPM', ...
                                              'Angle_degrees', 'BoxDensity_percent', 'ScaleFactor', ...
                                              'SlipDetected', 'SlipFrameName', 'SlipTimestamp_seconds', 'SlipAngle_degrees', ...
                                              'SlipMaterialPixelsInBox', 'SlipMaterialFractionInBox', 'SlipExportFolder'});
    else
        resultsTable = table(imageNames', angles', densities', scaleFactors', ...
                            slipDetectedValues, slipFrameNameValues, slipTimestampSeconds, slipAngleValues, ...
                            slipMaterialPixelValues, slipMaterialFractionValues, slipExportDirValues, ...
                            'VariableNames', {'ImageName', 'Angle_degrees', 'BoxDensity_percent', 'ScaleFactor', ...
                                              'SlipDetected', 'SlipFrameName', 'SlipTimestamp_seconds', 'SlipAngle_degrees', ...
                                              'SlipMaterialPixelsInBox', 'SlipMaterialFractionInBox', 'SlipExportFolder'});
    end

    rotationNumbers = (1:numel(angles))';
    angleValues = angles(:);
    if isVideoMode && numel(frameTimes) == numel(angles)
        timestampSeconds = frameTimes(:);
    else
        timestampSeconds = nan(numel(angles), 1);
    end
    alignedRotationTable = table(rotationNumbers, timestampSeconds, rotationFrameIndexValues, rotationFrameCountValues, rotationRpmValues, angleValues, ...
                                slipDetectedValues, slipTimestampSeconds, slipAngleValues, slipFrameNameValues, ...
                                slipMaterialPixelValues, slipMaterialFractionValues, slipExportDirValues, ...
                                'VariableNames', {'Rotation', 'Timestamp_seconds', 'AlignmentFrame', 'RotationFrameCount', 'Rotation_RPM', 'Angle_degrees', ...
                                                  'SlipDetected', 'SlipTimestamp_seconds', 'SlipAngle_degrees', 'SlipFrameName', ...
                                                  'SlipMaterialPixelsInBox', 'SlipMaterialFractionInBox', 'SlipExportFolder'});
    
    % Save as CSV (human-readable)
    writetable(resultsTable, csvFile);
    fprintf('✓ CSV Results saved to: %s\n', csvFile);

    if exportAlignedValidationSummaryCsv
        alignedRotationCsvFile = fullfile(resultsFolder, [experimentName, alignedValidationSummaryCsvSuffix, '.csv']);
        writetable(alignedRotationTable, alignedRotationCsvFile);
        fprintf('✓ Aligned rotation summary CSV saved to: %s\n', alignedRotationCsvFile);
    else
        alignedRotationCsvFile = '';
    end

    if isVideoMode
        sourceFileForCombinedCsv = currentVideoFile;
    else
        sourceFileForCombinedCsv = imageFolder;
    end
    combinedRotationNumbers = (numel(combinedAlignmentAngles) + (1:numel(angles)))';
    combinedAlignmentSourceFiles = [combinedAlignmentSourceFiles; repmat({sourceFileForCombinedCsv}, numel(angles), 1)];
    combinedAlignmentFrameNames = [combinedAlignmentFrameNames; imageNames(:)];
    combinedAlignmentRotations = [combinedAlignmentRotations; combinedRotationNumbers];
    combinedAlignmentTimestamps = [combinedAlignmentTimestamps; timestampSeconds];
    combinedAlignmentFrameIndices = [combinedAlignmentFrameIndices; rotationFrameIndexValues];
    combinedRotationFrameCounts = [combinedRotationFrameCounts; rotationFrameCountValues];
    combinedRotationRpms = [combinedRotationRpms; rotationRpmValues];
    combinedAlignmentAngles = [combinedAlignmentAngles; angleValues];
    combinedSlipDetected = [combinedSlipDetected; slipDetectedValues];
    combinedSlipFrameNames = [combinedSlipFrameNames; slipFrameNameValues];
    combinedSlipTimestamps = [combinedSlipTimestamps; slipTimestampSeconds];
    combinedSlipAngles = [combinedSlipAngles; slipAngleValues];
    combinedSlipMaterialPixelsInBox = [combinedSlipMaterialPixelsInBox; slipMaterialPixelValues];
    combinedSlipMaterialFractionInBox = [combinedSlipMaterialFractionInBox; slipMaterialFractionValues];
    combinedSlipExportDirs = [combinedSlipExportDirs; slipExportDirValues];

    combinedLayoutLabel = getCombinedOutputRowLabel(sourceFileForCombinedCsv, videoFolder, inputMode);
    existingLayoutRow = find(strcmp(combinedLayoutSubfolderLabels, combinedLayoutLabel), 1);
    if isempty(existingLayoutRow)
        combinedLayoutSubfolderLabels{end+1, 1} = combinedLayoutLabel;
        combinedLayoutPlaneAngles{end+1, 1} = angleValues(:)';
        combinedLayoutSlipAngles{end+1, 1} = slipAngleValues(:)';
    else
        combinedLayoutPlaneAngles{existingLayoutRow} = [combinedLayoutPlaneAngles{existingLayoutRow}, angleValues(:)'];
        combinedLayoutSlipAngles{existingLayoutRow} = [combinedLayoutSlipAngles{existingLayoutRow}, slipAngleValues(:)'];
    end
    
    % Save as MAT file (includes all data for later analysis)
    
    % Package all results
    analysisResults = struct();
    analysisResults.imageNames = imageNames;
    analysisResults.angles = angles;
    analysisResults.densities = densities;
    analysisResults.scaleFactors = scaleFactors;
    analysisResults.segmentationData = segmentationData;
    analysisResults.processingTimes = processingTimes;
    analysisResults.rotationFrameIndices = rotationFrameIndexValues;
    analysisResults.rotationFrameCounts = rotationFrameCountValues;
    analysisResults.rotationRpms = rotationRpmValues;
    analysisResults.alignedRotationSummary = alignedRotationTable;
    analysisResults.alignedRotationSummaryCsvFile = alignedRotationCsvFile;
    analysisResults.slipDetected = slipDetectedValues;
    analysisResults.slipFrameNames = slipFrameNameValues;
    analysisResults.slipFrameTimes = slipTimestampSeconds;
    analysisResults.slipAngles = slipAngleValues;
    analysisResults.slipMaterialPixelsInBox = slipMaterialPixelValues;
    analysisResults.slipMaterialFractionInBox = slipMaterialFractionValues;
    analysisResults.slipExportDirs = slipExportDirValues;
    
    % Calibration parameters (needed for visualization)
    analysisResults.calibration = struct();
    analysisResults.calibration.pRef = pRef;
    analysisResults.calibration.mRef = mRef;
    analysisResults.calibration.cx = cx;
    analysisResults.calibration.cy = cy;
    analysisResults.calibration.r = r;
    analysisResults.validationBox = validationBox;
    analysisResults.validationPlaneCalibration = struct();
    analysisResults.validationPlaneCalibration.colorLabel = planeColorLabel;
    analysisResults.validationPlaneCalibration.hMin = hMin_plane;
    analysisResults.validationPlaneCalibration.hMax = hMax_plane;
    analysisResults.validationPlaneCalibration.sMin = sMin_plane;
    analysisResults.validationPlaneCalibration.vMin = vMin_plane;
    analysisResults.validationPlaneCalibration.edgeThreshold = validationPlaneEdgeThreshold;
    analysisResults.validationPlaneCalibration.segmentationDilationRadius = validationPlaneDilationRadius;
    analysisResults.validationPlaneCalibration.segmentationClosingRadius = validationPlaneClosingRadius;
    analysisResults.validationBoxTolerance = validationBoxTolerance;
    
    % Processing parameters
    analysisResults.parameters = struct();
    analysisResults.parameters.minArea = minArea;
    analysisResults.parameters.smoothWindow = smoothWindow;
    analysisResults.parameters.drumTolerance = drumTolerance;
    analysisResults.parameters.diameterTolerance = diameterTolerance;
    analysisResults.parameters.validationBoxTolerance = validationBoxTolerance;
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
    analysisResults.parameters.validationBoxCalibrationExportFolder = validationBoxCalibrationExportFolder;
    analysisResults.parameters.exportAlignedValidationFrameImages = exportAlignedValidationFrameImages;
    analysisResults.parameters.alignedValidationFrameFolder = alignedValidationFrameFolder;
    analysisResults.parameters.exportAlignedValidationSummaryCsv = exportAlignedValidationSummaryCsv;
    analysisResults.parameters.alignedValidationSummaryCsvSuffix = alignedValidationSummaryCsvSuffix;
    analysisResults.parameters.combinedAlignedValidationCsvFileName = combinedAlignedValidationCsvFileName;
    analysisResults.parameters.combinedAlignedValidationWorkbookFileName = combinedAlignedValidationWorkbookFileName;
    analysisResults.parameters.exportCombinedSubfolderWorkbook = exportCombinedSubfolderWorkbook;
    analysisResults.parameters.analyzeOnlyAlignedValidationBox = analyzeOnlyAlignedValidationBox;
    analysisResults.parameters.validationBoxAlignmentToleranceDegrees = validationBoxAlignmentToleranceDegrees;
    analysisResults.parameters.validationBoxRightSideMinOffsetFraction = validationBoxRightSideMinOffsetFraction;
    analysisResults.parameters.validationBoxMinFramesBetweenAnalyses = validationBoxMinFramesBetweenAnalyses;
    analysisResults.parameters.showAnalyzedFramePreview = showAnalyzedFramePreview;
    analysisResults.parameters.extendAlignedValidationBoxForAnalysis = extendAlignedValidationBoxForAnalysis;
    analysisResults.parameters.alignedValidationBoxLengthExtensionFraction = alignedValidationBoxLengthExtensionFraction;
    analysisResults.parameters.enableSlipAngleTracking = enableSlipAngleTracking;
    analysisResults.parameters.exportSlipValidationFrameImages = exportSlipValidationFrameImages;
    analysisResults.parameters.slipMinFramesAfterAlignment = slipMinFramesAfterAlignment;
    analysisResults.parameters.slipSkipFramesAfterDetection = slipSkipFramesAfterDetection;
    analysisResults.parameters.slipMaterialInsideMaxPixels = slipMaterialInsideMaxPixels;
    analysisResults.parameters.slipMaterialInsideMaxFraction = slipMaterialInsideMaxFraction;
    analysisResults.parameters.processingDate = datetime('now');
    
    analysisResults.summary = struct();
    analysisResults.summary.totalProcessed = successCount + failCount + skippedAlignmentCount + slipPostDetectionSkippedCount;
    analysisResults.summary.successCount = successCount;
    analysisResults.summary.failCount = failCount;
    analysisResults.summary.skippedAlignmentCount = skippedAlignmentCount;
    analysisResults.summary.slipPostDetectionSkippedCount = slipPostDetectionSkippedCount;
    analysisResults.summary.alignmentCandidateCount = alignmentCandidateCount;
    analysisResults.summary.slipDetectedCount = sum(slipDetectedValues);
    
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
    
    fprintf('\n--- NEXT STEPS ---\n');
    fprintf('1. Review the validation-box overlay exports if exportInitialFrameOverlays is enabled\n');
    fprintf('2. Open %s in a spreadsheet application to review the frame-level validation angles\n', csvFile);
    if exportAlignedValidationSummaryCsv
        fprintf('3. Open %s for rotation/timestamp/angle rows and slip-angle columns\n', alignedRotationCsvFile);
        fprintf('4. Use the MAT file for custom plots of angle and box density over time\n\n');
    else
        fprintf('3. Use the MAT file for custom plots of angle and box density over time\n\n');
    end
end

end

if isVideoInput && ~calibrationComplete
    error('No readable videos were processed. If these are simulation videos, convert them to H.264 MP4 or install ffmpeg so the automatic conversion fallback can run.');
end

combinedOutputFolder = getCombinedOutputFolder(inputMode, imageFolder, videoFile, videoFolder, ...
                                              resultsRootFolder, saveResultsNextToSourceVideo);
if ~isempty(combinedOutputFolder) && ~isfolder(combinedOutputFolder)
    mkdir(combinedOutputFolder);
end

if exportAlignedValidationSummaryCsv && ~isempty(combinedAlignmentAngles)
    combinedAlignmentTable = table(combinedAlignmentSourceFiles, combinedAlignmentFrameNames, ...
                                   combinedAlignmentRotations, combinedAlignmentTimestamps, combinedAlignmentFrameIndices, ...
                                   combinedRotationFrameCounts, combinedRotationRpms, combinedAlignmentAngles, ...
                                   combinedSlipDetected, combinedSlipFrameNames, combinedSlipTimestamps, combinedSlipAngles, ...
                                   combinedSlipMaterialPixelsInBox, combinedSlipMaterialFractionInBox, combinedSlipExportDirs, ...
                                   'VariableNames', {'SourceFile', 'FrameName', 'Rotation', 'Timestamp_seconds', 'AlignmentFrame', ...
                                                     'RotationFrameCount', 'Rotation_RPM', 'Angle_degrees', ...
                                                     'SlipDetected', 'SlipFrameName', 'SlipTimestamp_seconds', 'SlipAngle_degrees', ...
                                                     'SlipMaterialPixelsInBox', 'SlipMaterialFractionInBox', 'SlipExportFolder'});
    combinedAlignmentCsvFile = fullfile(combinedOutputFolder, combinedAlignedValidationCsvFileName);
    writetable(combinedAlignmentTable, combinedAlignmentCsvFile);
    fprintf('✓ Combined aligned validation CSV saved to: %s\n', combinedAlignmentCsvFile);
end

if exportCombinedSubfolderWorkbook && ~isempty(combinedLayoutPlaneAngles)
    combinedOutputMainFolderName = getCombinedOutputMainFolderName(inputMode, imageFolder, videoFile, videoFolder);
    combinedAlignmentWorkbookFile = writeCombinedSubfolderRotationWorkbook(combinedOutputFolder, ...
        combinedAlignedValidationWorkbookFileName, combinedOutputMainFolderName, ...
        combinedLayoutSubfolderLabels, combinedLayoutPlaneAngles, combinedLayoutSlipAngles);
    fprintf('✓ Combined subfolder workbook saved to: %s\n', combinedAlignmentWorkbookFile);
end

%% ========== CENTRALIZED HELPER FUNCTIONS (eliminate redundancy) ==========


function [rotationFrameCounts, rotationRpms] = calculateRotationRpmFromFrameIndices(rotationFrameIndices, frameRate)
    % RPM is assigned to the alignment that completes the rotation from the
    % previous accepted alignment to the current accepted alignment.
    rotationFrameIndices = rotationFrameIndices(:);
    rotationCount = numel(rotationFrameIndices);
    rotationFrameCounts = nan(rotationCount, 1);
    rotationRpms = nan(rotationCount, 1);

    if rotationCount < 2 || isempty(frameRate) || isnan(frameRate) || ~isfinite(frameRate) || frameRate <= 0
        return;
    end

    for rotationIdx = 2:rotationCount
        previousFrame = rotationFrameIndices(rotationIdx - 1);
        currentFrame = rotationFrameIndices(rotationIdx);
        if isfinite(previousFrame) && isfinite(currentFrame)
            frameDelta = currentFrame - previousFrame;
            if frameDelta > 0
                rotationFrameCounts(rotationIdx) = frameDelta;
                rotationRpms(rotationIdx) = 60 * frameRate / frameDelta;
            end
        end
    end
end

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

function totalFrames = countReadableVideoFrames(videoObj)
    % Count frames for full-video analysis so the processing loop visits
    % every readable frame in each newly loaded video.
    totalFrames = [];

    try
        if isprop(videoObj, 'NumFrames') && ~isempty(videoObj.NumFrames) && ...
           isfinite(videoObj.NumFrames) && videoObj.NumFrames > 0
            totalFrames = floor(videoObj.NumFrames);
        end
    catch
        totalFrames = [];
    end

    if isempty(totalFrames)
        originalTime = videoObj.CurrentTime;
        cleanupObj = onCleanup(@() restoreVideoCurrentTime(videoObj, originalTime));
        videoObj.CurrentTime = 0;
        countedFrames = 0;
        while hasFrame(videoObj)
            readFrame(videoObj);
            countedFrames = countedFrames + 1;
        end
        totalFrames = countedFrames;
        clear cleanupObj;
        videoObj.CurrentTime = originalTime;
    end

    if isempty(totalFrames) || totalFrames < 1
        error('No readable frames were found in this video.');
    end
end

function restoreVideoCurrentTime(videoObj, originalTime)
    try
        videoObj.CurrentTime = originalTime;
    catch
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

    baseName = sprintf('Validation_results_%s_%s', parentFolderName, sourceFolderName);
end

function combinedOutputFolder = getCombinedOutputFolder(inputMode, imageFolder, videoFile, videoFolder, resultsRootFolder, saveResultsNextToSourceVideo)
    combinedOutputFolder = resultsRootFolder;
    if saveResultsNextToSourceVideo
        switch lower(strtrim(inputMode))
            case 'video-folder'
                combinedOutputFolder = videoFolder;
            case 'video'
                combinedOutputFolder = fileparts(videoFile);
            case 'images'
                combinedOutputFolder = imageFolder;
        end
    end
    if isempty(combinedOutputFolder)
        combinedOutputFolder = resultsRootFolder;
    end
end

function mainFolderName = getCombinedOutputMainFolderName(inputMode, imageFolder, videoFile, videoFolder)
    switch lower(strtrim(inputMode))
        case 'video-folder'
            inputFolder = videoFolder;
        case 'video'
            inputFolder = fileparts(videoFile);
        case 'images'
            inputFolder = imageFolder;
        otherwise
            inputFolder = pwd;
    end
    mainFolderName = getFolderDisplayName(inputFolder);
end

function rowLabel = getCombinedOutputRowLabel(sourceFileOrFolder, mainFolder, inputMode)
    sourcePath = char(sourceFileOrFolder);
    if isfile(sourcePath)
        sourceFolder = fileparts(sourcePath);
    else
        sourceFolder = sourcePath;
    end

    if strcmpi(strtrim(inputMode), 'video-folder')
        rowLabel = getRelativeFolderLabel(sourceFolder, mainFolder);
    else
        rowLabel = getFolderDisplayName(sourceFolder);
    end
    if isempty(rowLabel)
        rowLabel = sourceFolder;
    end
end

function rowLabel = getRelativeFolderLabel(sourceFolder, rootFolder)
    sourceFolder = stripTrailingFileSeparators(sourceFolder);
    rootFolder = stripTrailingFileSeparators(rootFolder);

    if isempty(sourceFolder)
        rowLabel = '';
        return;
    end
    if isempty(rootFolder)
        rowLabel = getFolderDisplayName(sourceFolder);
        return;
    end
    if strcmp(sourceFolder, rootFolder)
        rowLabel = getFolderDisplayName(sourceFolder);
        return;
    end

    rootPrefix = [rootFolder, filesep];
    if strncmp(sourceFolder, rootPrefix, numel(rootPrefix))
        rowLabel = sourceFolder(numel(rootPrefix)+1:end);
        rowLabel = strrep(rowLabel, filesep, '/');
    else
        rowLabel = getFolderDisplayName(sourceFolder);
    end
end

function folderName = getFolderDisplayName(folderPath)
    folderPath = stripTrailingFileSeparators(folderPath);
    [~, folderName] = fileparts(folderPath);
    if isempty(folderName)
        folderName = folderPath;
    end
end

function pathValue = stripTrailingFileSeparators(pathValue)
    pathValue = char(pathValue);
    while numel(pathValue) > 1 && (pathValue(end) == filesep || pathValue(end) == '/')
        pathValue(end) = [];
    end
end

function workbookFile = writeCombinedSubfolderRotationWorkbook(outputFolder, workbookFileName, mainFolderName, subfolderLabels, planeAngleRows, slipAngleRows)
    if isempty(outputFolder)
        outputFolder = pwd;
    end
    if ~isfolder(outputFolder)
        mkdir(outputFolder);
    end

    maxRotations = 0;
    for rowIdx = 1:numel(planeAngleRows)
        maxRotations = max(maxRotations, numel(planeAngleRows{rowIdx}));
    end
    if maxRotations == 0
        error('Cannot create combined subfolder workbook because there are no rotation measurements.');
    end

    headerRows = 3;
    outputCells = repmat({''}, headerRows + numel(subfolderLabels), 1 + 2 * maxRotations);
    outputCells{1, 1} = mainFolderName;
    outputCells{3, 1} = 'Eksperiment:';

    for rotationIdx = 1:maxRotations
        firstRotationColumn = 2 + (rotationIdx - 1) * 2;
        outputCells{2, firstRotationColumn} = sprintf('Rotation %d', rotationIdx);
        outputCells{3, firstRotationColumn} = 'Plane_angle';
        outputCells{3, firstRotationColumn + 1} = 'Slip_Angle';
    end

    for rowIdx = 1:numel(subfolderLabels)
        outputRow = headerRows + rowIdx;
        outputCells{outputRow, 1} = subfolderLabels{rowIdx};
        planeAngles = planeAngleRows{rowIdx};
        slipAngles = [];
        if rowIdx <= numel(slipAngleRows)
            slipAngles = slipAngleRows{rowIdx};
        end

        for rotationIdx = 1:numel(planeAngles)
            firstRotationColumn = 2 + (rotationIdx - 1) * 2;
            outputCells{outputRow, firstRotationColumn} = planeAngles(rotationIdx);
            if rotationIdx <= numel(slipAngles) && ~isnan(slipAngles(rotationIdx))
                outputCells{outputRow, firstRotationColumn + 1} = slipAngles(rotationIdx);
            end
        end
    end

    workbookFile = fullfile(outputFolder, workbookFileName);
    writecell(outputCells, workbookFile, 'FileType', 'spreadsheet');
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

%% ========== VALIDATION BOX HELPER FUNCTIONS ==========

function validationBoxScaled = scaleValidationBox(validationBox, scaleFactor)
    validationBoxScaled = validationBox;
    validationBoxScaled.xMin = validationBox.xMin * scaleFactor;
    validationBoxScaled.xMax = validationBox.xMax * scaleFactor;
    validationBoxScaled.yMin = validationBox.yMin * scaleFactor;
    validationBoxScaled.yMax = validationBox.yMax * scaleFactor;
    validationBoxScaled.baseY = validationBox.baseY * scaleFactor;
    validationBoxScaled.width = validationBox.width * scaleFactor;
    validationBoxScaled.height = validationBox.height * scaleFactor;
    validationBoxScaled.corners = validationBox.corners * scaleFactor;
    validationBoxScaled.lengthLine = validationBox.lengthLine * scaleFactor;
    validationBoxScaled.areaPixels = validationBox.areaPixels * scaleFactor^2;
    if isfield(validationBox, 'basePoint1')
        validationBoxScaled.basePoint1 = validationBox.basePoint1 * scaleFactor;
    end
    if isfield(validationBox, 'basePoint2')
        validationBoxScaled.basePoint2 = validationBox.basePoint2 * scaleFactor;
    end
    if isfield(validationBox, 'center')
        validationBoxScaled.center = validationBox.center * scaleFactor;
    end
    if isfield(validationBox, 'planeCenter')
        validationBoxScaled.planeCenter = validationBox.planeCenter * scaleFactor;
    end
    if isfield(validationBox, 'planeBoundaryX')
        validationBoxScaled.planeBoundaryX = validationBox.planeBoundaryX * scaleFactor;
        validationBoxScaled.planeBoundaryY = validationBox.planeBoundaryY * scaleFactor;
    end
end

function boxMask = createValidationBoxMask(frameSize, validationBox)
    rows = frameSize(1);
    cols = frameSize(2);
    corners = validationBox.corners;
    boxMask = poly2mask(corners(:,1), corners(:,2), rows, cols);
end

function [validationBox, planeMask, edgeMask, xPlaneBoundary, yPlaneBoundary] = ...
    deriveValidationBoxFromPlane(frame, cx, cy, r, minArea, hMin, hMax, sMin, vMin, edgeThreshold, dilationRadius, closingRadius)
    [rows, cols, ~] = size(frame);
    [X, Y] = meshgrid(1:cols, 1:rows);
    drumMask = sqrt((X - cx).^2 + (Y - cy).^2) <= r;

    planeMaskRaw = createColorSegmentationMask(frame, hMin, hMax, sMin, vMin, dilationRadius, closingRadius, minArea);
    planeMaskRaw = planeMaskRaw & drumMask;
    planeMaskRaw = bwareaopen(planeMaskRaw, minArea);
    planeMaskRaw = imfill(planeMaskRaw, 'holes') & drumMask;

    validationBox = [];
    planeMask = false(size(planeMaskRaw));
    edgeMask = false(size(planeMaskRaw));
    xPlaneBoundary = [];
    yPlaneBoundary = [];

    cc = bwconncomp(planeMaskRaw);
    if cc.NumObjects == 0
        return;
    end

    stats = regionprops(cc, 'Area');
    [~, idxLargest] = max([stats.Area]);
    planeMask(cc.PixelIdxList{idxLargest}) = true;

    [edgeMask, xPlaneBoundary, yPlaneBoundary] = detectBoundaryEdgePoints(planeMask, edgeThreshold);
    if numel(xPlaneBoundary) < 10
        [yPlaneBoundary, xPlaneBoundary] = find(bwperim(planeMask, 8));
        xPlaneBoundary = xPlaneBoundary(:);
        yPlaneBoundary = yPlaneBoundary(:);
    end

    if numel(xPlaneBoundary) < 10
        return;
    end

    [xPlaneInside, yPlaneInside] = filterBoundaryPointsWithinDrum(xPlaneBoundary, yPlaneBoundary, cx, cy, r, 0);
    if numel(xPlaneInside) >= 10
        xPlaneBoundary = xPlaneInside;
        yPlaneBoundary = yPlaneInside;
    end

    planePoints = [xPlaneBoundary(:), yPlaneBoundary(:)];
    planeCenter = mean(planePoints, 1);
    centeredPoints = planePoints - planeCenter;
    if size(centeredPoints, 1) < 2
        return;
    end

    covarianceMatrix = cov(centeredPoints);
    [eigVectors, eigValues] = eig(covarianceMatrix);
    [~, majorIdx] = max(diag(eigValues));
    axisU = eigVectors(:, majorIdx)';
    if axisU(1) < 0
        axisU = -axisU;
    end
    axisU = axisU ./ max(norm(axisU), eps);

    axisN = [-axisU(2), axisU(1)];
    if axisN(2) > 0
        axisN = -axisN;
    end
    axisN = axisN ./ max(norm(axisN), eps);

    lengthCoordinates = centeredPoints * axisU';
    normalCoordinates = centeredPoints * axisN';
    tMin = min(lengthCoordinates);
    tMax = max(lengthCoordinates);
    baseOffset = max(normalCoordinates);
    if tMax <= tMin
        return;
    end

    basePoint1 = planeCenter + tMin * axisU + baseOffset * axisN;
    basePoint2 = planeCenter + tMax * axisU + baseOffset * axisN;
    topPoint1 = basePoint1 + r * axisN;
    topPoint2 = basePoint2 + r * axisN;
    corners = [topPoint1; topPoint2; basePoint2; basePoint1];
    lengthLine = [basePoint1; basePoint2];

    xMin = min(corners(:,1));
    xMax = max(corners(:,1));
    yMin = min(corners(:,2));
    yMax = max(corners(:,2));
    baseY = mean(lengthLine(:,2));
    normalDirection = -1;
    angleDegrees = atan2d(axisU(2), axisU(1));
    boxLength = tMax - tMin;

    if yMax <= yMin
        return;
    end

    boxMask = poly2mask(corners(:,1), corners(:,2), rows, cols);

    validationBox = struct();
    validationBox.xMin = xMin;
    validationBox.xMax = xMax;
    validationBox.yMin = yMin;
    validationBox.yMax = yMax;
    validationBox.baseY = baseY;
    validationBox.width = boxLength;
    validationBox.height = r;
    validationBox.requestedHeight = r;
    validationBox.normalDirection = normalDirection;
    validationBox.corners = corners;
    validationBox.lengthLine = lengthLine;
    validationBox.basePoint1 = basePoint1;
    validationBox.basePoint2 = basePoint2;
    validationBox.axisU = axisU;
    validationBox.axisN = axisN;
    validationBox.angleDegrees = angleDegrees;
    validationBox.center = mean(corners, 1);
    validationBox.planeCenter = planeCenter;
    validationBox.areaPixels = sum(boxMask(:));
    validationBox.planeBoundaryX = xPlaneBoundary(:)';
    validationBox.planeBoundaryY = yPlaneBoundary(:)';
end

function [xFiltered, yFiltered] = filterBoundaryPointsWithinValidationBox(xBoundary, yBoundary, validationBox, boxTolerance)
    if nargin < 4, boxTolerance = 0; end

    xBoundary = xBoundary(:);
    yBoundary = yBoundary(:);
    n = min(numel(xBoundary), numel(yBoundary));
    xBoundary = xBoundary(1:n);
    yBoundary = yBoundary(1:n);

    if isempty(xBoundary) || isempty(validationBox)
        xFiltered = [];
        yFiltered = [];
        return;
    end

    validationBox = applyValidationBoxTolerance(validationBox, boxTolerance);
    corners = validationBox.corners;
    validIdx = inpolygon(xBoundary, yBoundary, corners(:,1), corners(:,2));
    xFiltered = xBoundary(validIdx);
    yFiltered = yBoundary(validIdx);
end

function validationBoxOut = applyValidationBoxTolerance(validationBox, boxTolerance)
    validationBoxOut = validationBox;
    if isempty(validationBox) || boxTolerance <= 0
        return;
    end

    maxTolerance = max(0, min(validationBox.width, validationBox.height) / 2 - 1);
    boxTolerance = min(boxTolerance, maxTolerance);
    if boxTolerance <= 0
        return;
    end

    if isfield(validationBox, 'axisU') && isfield(validationBox, 'axisN') && ...
       isfield(validationBox, 'basePoint1') && isfield(validationBox, 'basePoint2')
        axisU = validationBox.axisU ./ max(norm(validationBox.axisU), eps);
        axisN = validationBox.axisN ./ max(norm(validationBox.axisN), eps);
        basePoint1 = validationBox.basePoint1 + boxTolerance * axisU + boxTolerance * axisN;
        basePoint2 = validationBox.basePoint2 - boxTolerance * axisU + boxTolerance * axisN;
        usableHeight = max(validationBox.height - 2 * boxTolerance, 1);
        topPoint1 = basePoint1 + usableHeight * axisN;
        topPoint2 = basePoint2 + usableHeight * axisN;
        validationBoxOut.basePoint1 = basePoint1;
        validationBoxOut.basePoint2 = basePoint2;
        validationBoxOut.corners = [topPoint1; topPoint2; basePoint2; basePoint1];
        validationBoxOut.lengthLine = [basePoint1; basePoint2];
        validationBoxOut.xMin = min(validationBoxOut.corners(:,1));
        validationBoxOut.xMax = max(validationBoxOut.corners(:,1));
        validationBoxOut.yMin = min(validationBoxOut.corners(:,2));
        validationBoxOut.yMax = max(validationBoxOut.corners(:,2));
        validationBoxOut.width = norm(basePoint2 - basePoint1);
        validationBoxOut.height = usableHeight;
        validationBoxOut.baseY = mean(validationBoxOut.lengthLine(:,2));
        validationBoxOut.center = mean(validationBoxOut.corners, 1);
        validationBoxOut.areaPixels = max(validationBoxOut.width, 0) * max(validationBoxOut.height, 0);
        return;
    end

    validationBoxOut.xMin = validationBox.xMin + boxTolerance;
    validationBoxOut.xMax = validationBox.xMax - boxTolerance;
    validationBoxOut.yMin = validationBox.yMin + boxTolerance;
    validationBoxOut.yMax = validationBox.yMax - boxTolerance;
    validationBoxOut.width = validationBoxOut.xMax - validationBoxOut.xMin;
    validationBoxOut.height = validationBoxOut.yMax - validationBoxOut.yMin;
    validationBoxOut.baseY = min(max(validationBox.baseY, validationBoxOut.yMin), validationBoxOut.yMax);
    validationBoxOut.corners = [validationBoxOut.xMin, validationBoxOut.yMin; ...
                                validationBoxOut.xMax, validationBoxOut.yMin; ...
                                validationBoxOut.xMax, validationBoxOut.yMax; ...
                                validationBoxOut.xMin, validationBoxOut.yMax];
    validationBoxOut.lengthLine = [validationBoxOut.xMin, validationBoxOut.baseY; validationBoxOut.xMax, validationBoxOut.baseY];
    validationBoxOut.areaPixels = max(validationBoxOut.width, 0) * max(validationBoxOut.height, 0);
end

function validationBoxOut = extendValidationBoxTowardOppositeDrumSide(validationBox, cx, cy, r, extensionLength)
    validationBoxOut = validationBox;
    if isempty(validationBox) || extensionLength <= 0
        return;
    end
    if ~isfield(validationBox, 'axisU') || ~isfield(validationBox, 'axisN') || ...
       ~isfield(validationBox, 'basePoint1') || ~isfield(validationBox, 'basePoint2')
        return;
    end

    axisU = validationBox.axisU ./ max(norm(validationBox.axisU), eps);
    axisN = validationBox.axisN ./ max(norm(validationBox.axisN), eps);
    basePoint1 = validationBox.basePoint1;
    basePoint2 = validationBox.basePoint2;

    if isfield(validationBox, 'planeCenter')
        planeCenter = validationBox.planeCenter;
    elseif isfield(validationBox, 'center')
        planeCenter = validationBox.center;
    else
        planeCenter = mean(validationBox.corners, 1);
    end

    extensionLength = min(max(extensionLength, 0), max(2 * r, 1));
    centerDirection = [cx, cy] - planeCenter;
    projectionToDrumCenter = dot(centerDirection, axisU);
    if projectionToDrumCenter <= 0
        basePoint1 = basePoint1 - extensionLength * axisU;
        extensionDirection = -axisU;
        extendedEnd = 'basePoint1';
    else
        basePoint2 = basePoint2 + extensionLength * axisU;
        extensionDirection = axisU;
        extendedEnd = 'basePoint2';
    end

    height = validationBox.height;
    topPoint1 = basePoint1 + height * axisN;
    topPoint2 = basePoint2 + height * axisN;
    corners = [topPoint1; topPoint2; basePoint2; basePoint1];

    validationBoxOut.basePoint1 = basePoint1;
    validationBoxOut.basePoint2 = basePoint2;
    validationBoxOut.corners = corners;
    validationBoxOut.lengthLine = [basePoint1; basePoint2];
    validationBoxOut.xMin = min(corners(:,1));
    validationBoxOut.xMax = max(corners(:,1));
    validationBoxOut.yMin = min(corners(:,2));
    validationBoxOut.yMax = max(corners(:,2));
    validationBoxOut.width = norm(basePoint2 - basePoint1);
    validationBoxOut.baseY = mean(validationBoxOut.lengthLine(:,2));
    validationBoxOut.center = mean(corners, 1);
    validationBoxOut.areaPixels = max(validationBoxOut.width, 0) * max(height, 0);
    validationBoxOut.extendedForAnalysis = true;
    validationBoxOut.lengthExtension = extensionLength;
    validationBoxOut.extensionDirection = extensionDirection;
    validationBoxOut.extendedEnd = extendedEnd;
    validationBoxOut.originalLengthLine = validationBox.lengthLine;
    validationBoxOut.originalWidth = validationBox.width;
end

function [xSurface, ySurface] = selectFreeSurfacePointsInValidationBox(xBoundary, yBoundary, validationBox, smoothWindow, yLower, yUpper)
    if nargin < 4, smoothWindow = 80; end
    if nargin < 5, yLower = 0.0; end
    if nargin < 6, yUpper = 1.0; end

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

    boxHeight = max(validationBox.yMax - validationBox.yMin, 1);
    yNorm = (yBoundary - validationBox.yMin) ./ boxHeight;
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

    nPoints = numel(ySurface);
    adaptiveWindow = max(round(nPoints * 0.05), 15);
    adaptiveWindow = min(adaptiveWindow, smoothWindow);
    if mod(adaptiveWindow, 2) == 0
        adaptiveWindow = adaptiveWindow + 1;
    end

    if nPoints >= adaptiveWindow && adaptiveWindow >= 5
        yMedian = medfilt1(ySurface, min(5, round(adaptiveWindow/3)));
        ySurface = smoothdata(yMedian, 'sgolay', adaptiveWindow);
    end
end

function [theta, xBoundaryFiltered, yBoundaryFiltered, xBoundarySelected, yBoundarySelected, m] = ...
    calculateFrameAngleInValidationBox(frame, mRef, validationBox, minArea, smoothWindow, yLower, yUpper, varargin)
    if nargin >= 11
        hMin = varargin{1};
        hMax = varargin{2};
        sMin = varargin{3};
        vMin = varargin{4};
    else
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
    validationBoxTolerance = 0;
    useDrumToleranceFilter = false;
    if numel(varargin) >= 12
        validationBoxTolerance = varargin{8};
        drumCx = varargin{9};
        drumCy = varargin{10};
        drumR = varargin{11};
        drumTolerance = varargin{12};
        useDrumToleranceFilter = true;
    elseif numel(varargin) >= 11
        drumCx = varargin{8};
        drumCy = varargin{9};
        drumR = varargin{10};
        drumTolerance = varargin{11};
        useDrumToleranceFilter = true;
    elseif numel(varargin) >= 8
        validationBoxTolerance = varargin{8};
    end

    colorMask = createColorSegmentationMask(frame, hMin, hMax, sMin, vMin, dilationRadius, closingRadius, minArea);

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

    usableValidationBox = applyValidationBoxTolerance(validationBox, validationBoxTolerance);
    [xBoundaryFiltered, yBoundaryFiltered] = filterBoundaryPointsWithinValidationBox(xBoundary, yBoundary, validationBox, validationBoxTolerance);
    if useDrumToleranceFilter
        [xBoundaryFiltered, yBoundaryFiltered] = filterBoundaryPointsWithinDrum(xBoundaryFiltered, yBoundaryFiltered, drumCx, drumCy, drumR, drumTolerance);
    end
    if numel(xBoundaryFiltered) < 20
        theta = NaN;
        xBoundarySelected = [];
        yBoundarySelected = [];
        m = NaN;
        return;
    end

    [xSurface, ySurface] = selectFreeSurfacePointsInValidationBox(xBoundaryFiltered, yBoundaryFiltered, usableValidationBox, smoothWindow, yLower, yUpper);
    if numel(xSurface) < 20
        theta = NaN;
        xBoundarySelected = [];
        yBoundarySelected = [];
        m = NaN;
        return;
    end

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

function density = calculateBoxDensity(frame, validationBox, varargin)
    if numel(varargin) >= 5
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
    elseif numel(varargin) >= 4
        hMin = varargin{1};
        hMax = varargin{2};
        sMin = varargin{3};
        vMin = varargin{4};
        minArea = 50;
        dilationRadius = 2;
        closingRadius = 4;
    else
        hMin = 0.15;
        hMax = 0.40;
        sMin = 0.10;
        vMin = 0.20;
        minArea = 50;
        dilationRadius = 2;
        closingRadius = 4;
    end

    colorMask = createColorSegmentationMask(frame, hMin, hMax, sMin, vMin, dilationRadius, closingRadius, minArea);
    boxMask = createValidationBoxMask(size(frame), validationBox);
    boxPixels = sum(boxMask(:));
    if boxPixels > 0
        density = 100 * sum(colorMask(:) & boxMask(:)) / boxPixels;
    else
        density = 0;
    end
end

function [hasSlipped, slipInfo] = detectMaterialSlippedFromValidationBox(frame, validationBox, boxTolerance, ...
    hMin, hMax, sMin, vMin, minArea, dilationRadius, closingRadius, ...
    drumCx, drumCy, drumR, drumTolerance, maxInsidePixels, maxInsideFraction)

    hasSlipped = false;
    slipInfo = struct('materialPixelsTotal', 0, 'materialPixelsInBox', 0, ...
                      'materialFractionInBox', NaN, 'reason', 'not evaluated', ...
                      'materialBoundaryX', [], 'materialBoundaryY', [], ...
                      'materialInsideBoundaryX', [], 'materialInsideBoundaryY', []);

    if isempty(validationBox) || ~isfield(validationBox, 'corners')
        slipInfo.reason = 'validation box not detected';
        return;
    end

    [rows, cols, ~] = size(frame);
    colorMask = createColorSegmentationMask(frame, hMin, hMax, sMin, vMin, dilationRadius, closingRadius, minArea);

    [X, Y] = meshgrid(1:cols, 1:rows);
    usableRadius = max(drumR - drumTolerance, 1);
    drumMask = sqrt((X - drumCx).^2 + (Y - drumCy).^2) <= usableRadius;
    materialMask = colorMask & drumMask;

    materialPixelsTotal = sum(materialMask(:));
    slipInfo.materialPixelsTotal = materialPixelsTotal;
    if materialPixelsTotal < max(1, minArea)
        slipInfo.reason = 'material segmentation too small';
        return;
    end

    usableValidationBox = applyValidationBoxTolerance(validationBox, boxTolerance);
    boxMask = createValidationBoxMask(size(frame), usableValidationBox);
    materialInsideMask = materialMask & boxMask;

    materialPixelsInBox = sum(materialInsideMask(:));
    materialFractionInBox = materialPixelsInBox / max(materialPixelsTotal, 1);
    slipInfo.materialPixelsInBox = materialPixelsInBox;
    slipInfo.materialFractionInBox = materialFractionInBox;
    slipInfo.maxInsidePixels = maxInsidePixels;
    slipInfo.maxInsideFraction = maxInsideFraction;

    materialBoundaryMask = bwperim(materialMask, 8);
    [yMaterialBoundary, xMaterialBoundary] = find(materialBoundaryMask);
    slipInfo.materialBoundaryX = xMaterialBoundary(:);
    slipInfo.materialBoundaryY = yMaterialBoundary(:);

    materialInsideBoundaryMask = bwperim(materialInsideMask, 8);
    [yInsideBoundary, xInsideBoundary] = find(materialInsideBoundaryMask);
    if isempty(xInsideBoundary) && materialPixelsInBox > 0
        [yInsideBoundary, xInsideBoundary] = find(materialInsideMask);
    end
    slipInfo.materialInsideBoundaryX = xInsideBoundary(:);
    slipInfo.materialInsideBoundaryY = yInsideBoundary(:);

    hasSlipped = materialPixelsInBox <= maxInsidePixels && materialFractionInBox <= maxInsideFraction;
    if hasSlipped
        slipInfo.reason = 'material no longer inside validation box';
    else
        slipInfo.reason = 'material still inside validation box';
    end
end

function drawValidationBox(validationBox, boxColor, lineWidth)
    if nargin < 2, boxColor = 'b'; end
    if nargin < 3, lineWidth = 2; end
    if isempty(validationBox) || ~isfield(validationBox, 'corners')
        return;
    end

    corners = validationBox.corners;
    closedCorners = [corners; corners(1,:)];
    plot(closedCorners(:,1), closedCorners(:,2), '-', 'Color', boxColor, 'LineWidth', lineWidth, 'DisplayName', 'Validation box');
    if isfield(validationBox, 'lengthLine')
        lengthDisplayName = 'Blue plane length';
        if isfield(validationBox, 'extendedForAnalysis') && validationBox.extendedForAnalysis
            lengthDisplayName = 'Extended analysis length';
        end
        plot(validationBox.lengthLine(:,1), validationBox.lengthLine(:,2), '--', ...
             'Color', boxColor, 'LineWidth', max(1, lineWidth - 0.5), 'DisplayName', lengthDisplayName);
    end
end

function zoomAxesToDrumDiameter(axHandle, cx, cy, r, frameSize)
    if isempty(axHandle) || ~isgraphics(axHandle) || isempty(r) || isnan(r) || r <= 0
        return;
    end

    rows = frameSize(1);
    cols = frameSize(2);
    xLimits = [max(1, cx - r), min(cols, cx + r)];
    yLimits = [max(1, cy - r), min(rows, cy + r)];

    if xLimits(2) > xLimits(1) && yLimits(2) > yLimits(1)
        xlim(axHandle, xLimits);
        ylim(axHandle, yLimits);
    end
end

function [isAligned, info] = isValidationBoxAlignedForAnalysis(validationBox, mRef, cx, r, angleToleranceDegrees, rightSideMinOffsetFraction)
    info = struct('enabled', true, 'isAligned', false, 'reason', 'blue plane not detected', ...
                  'angleDifferenceDegrees', NaN, 'planeAngleDegrees', NaN, ...
                  'referenceAngleDegrees', atan(mRef) * 180/pi, ...
                  'planeCenterX', NaN, 'planeCenterY', NaN, 'isRightSide', false);
    isAligned = false;

    if isempty(validationBox) || ~isstruct(validationBox) || ~isfield(validationBox, 'angleDegrees')
        return;
    end

    if isfield(validationBox, 'planeCenter')
        planeCenter = validationBox.planeCenter;
    elseif isfield(validationBox, 'center')
        planeCenter = validationBox.center;
    else
        planeCenter = [mean(validationBox.corners(:,1)), mean(validationBox.corners(:,2))];
    end

    referenceAngle = atan(mRef) * 180/pi;
    angleDifference = lineAngleDifferenceDegrees(validationBox.angleDegrees, referenceAngle);
    rightSideThreshold = cx + rightSideMinOffsetFraction * r;
    isRightSide = planeCenter(1) >= rightSideThreshold;
    isParallel = angleDifference <= angleToleranceDegrees;

    info.angleDifferenceDegrees = angleDifference;
    info.planeAngleDegrees = validationBox.angleDegrees;
    info.planeCenterX = planeCenter(1);
    info.planeCenterY = planeCenter(2);
    info.isRightSide = isRightSide;

    if ~isParallel
        info.reason = sprintf('plane not parallel: diff %.2f deg > %.2f deg', angleDifference, angleToleranceDegrees);
    elseif ~isRightSide
        info.reason = sprintf('plane not on right side: x %.1f < %.1f', planeCenter(1), rightSideThreshold);
    else
        isAligned = true;
        info.isAligned = true;
        info.reason = sprintf('aligned: diff %.2f deg, x %.1f', angleDifference, planeCenter(1));
    end
end

function diffDegrees = lineAngleDifferenceDegrees(angleA, angleB)
    diffDegrees = abs(mod(angleA - angleB + 90, 180) - 90);
end

function showValidationAnalysisPreview(frame, imageName, angle, density, segData, pauseForUser)
    fig = figure('Name', sprintf('Accepted validation frame: %s', imageName), 'NumberTitle', 'off', ...
                 'Position', [100, 100, 1200, 900]);
    imshow(frame);
    hold on;

    if isfield(segData, 'xBoundaryFiltered') && ~isempty(segData.xBoundaryFiltered)
        plot(segData.xBoundaryFiltered, segData.yBoundaryFiltered, 'c.', 'MarkerSize', 6, 'DisplayName', 'Filtered boundary');
    end
    if isfield(segData, 'xBoundarySelected') && ~isempty(segData.xBoundarySelected)
        plot(segData.xBoundarySelected, segData.yBoundarySelected, 'm.', 'MarkerSize', 9, 'DisplayName', 'Selected fit points');
    end

    if isfield(segData, 'detectedValidationBox_scaled') && isfield(segData, 'validationBoxExtendedForAnalysis') && segData.validationBoxExtendedForAnalysis
        drawValidationBox(segData.detectedValidationBox_scaled, [0.65, 0.65, 0.65], 1.5);
    end
    if isfield(segData, 'validationBox_scaled')
        drawValidationBox(segData.validationBox_scaled, [0.1, 0.45, 1.0], 3);
        if isfield(segData, 'validationBoxTolerance_scaled') && segData.validationBoxTolerance_scaled > 0
            drawValidationBox(applyValidationBoxTolerance(segData.validationBox_scaled, segData.validationBoxTolerance_scaled), [1.0, 0.55, 0.0], 2);
        end
    end

    if isfield(segData, 'cx_scaled') && isfield(segData, 'cy_scaled') && isfield(segData, 'r_scaled')
        thetaCircle = linspace(0, 2*pi, 300);
        plot(segData.cx_scaled + segData.r_scaled*cos(thetaCircle), ...
             segData.cy_scaled + segData.r_scaled*sin(thetaCircle), ...
             'y--', 'LineWidth', 2, 'DisplayName', 'Drum');
        zoomAxesToDrumDiameter(gca, segData.cx_scaled, segData.cy_scaled, segData.r_scaled, size(frame));
    end

    if isfield(segData, 'xBoundarySelected') && ~isempty(segData.xBoundarySelected) && isfield(segData, 'm')
        xLine = linspace(min(segData.xBoundarySelected)-50, max(segData.xBoundarySelected)+50, 100);
        yLine = segData.m * xLine + (mean(segData.yBoundarySelected) - segData.m * mean(segData.xBoundarySelected));
        plot(xLine, yLine, 'r-', 'LineWidth', 3, 'DisplayName', sprintf('Detected line %.2f deg', angle));
    end

    if isfield(segData, 'pRef_scaled')
        xRef = linspace(1, size(frame, 2), 200);
        yRef = polyval(segData.pRef_scaled, xRef);
        plot(xRef, yRef, 'w--', 'LineWidth', 2, 'DisplayName', 'Reference line');
    end

    extensionText = '';
    if isfield(segData, 'validationBoxExtendedForAnalysis') && segData.validationBoxExtendedForAnalysis && ...
       isfield(segData, 'validationBoxLengthExtension_scaled')
        extensionText = sprintf(' | extended box %.1f px', segData.validationBoxLengthExtension_scaled);
    end
    title(sprintf('%s | angle %.2f deg | box density %.1f%%%s', imageName, angle, density, extensionText), 'Interpreter', 'none');
    legend('Location', 'best');
    hold off;
    drawnow;

    if pauseForUser
        fprintf('Accepted validation frame preview shown. Press any key or click the figure to continue.\n');
        waitforbuttonpress;
        if isgraphics(fig)
            close(fig);
        end
    end
end

function instanceDir = exportAlignedValidationInstance(frame, imageName, angle, density, segData, exportRoot, instanceIndex, processingTimeSeconds)
    if nargin < 8, processingTimeSeconds = NaN; end
    if ~isfolder(exportRoot)
        mkdir(exportRoot);
    end

    [~, imageBaseName, ~] = fileparts(imageName);
    safeImageName = makeSafeFileName(imageBaseName);
    instanceDir = fullfile(exportRoot, sprintf('%03d_%s', instanceIndex, safeImageName));
    suffix = 1;
    baseInstanceDir = instanceDir;
    while isfolder(instanceDir)
        suffix = suffix + 1;
        instanceDir = sprintf('%s_%d', baseInstanceDir, suffix);
    end
    mkdir(instanceDir);

    overlayFile = fullfile(instanceDir, 'validation_alignment_overlay.png');
    metadataFile = fullfile(instanceDir, 'validation_alignment_metadata.txt');
    metadataMatFile = fullfile(instanceDir, 'validation_alignment_metadata.mat');

    fig = figure('Visible', 'off', 'Units', 'pixels', 'Position', [100, 100, 1400, 1000]);
    imshow(frame);
    hold on;

    if isfield(segData, 'xBoundaryFiltered') && ~isempty(segData.xBoundaryFiltered)
        plot(segData.xBoundaryFiltered, segData.yBoundaryFiltered, 'c.', 'MarkerSize', 6, 'DisplayName', 'Filtered material boundary');
    end
    if isfield(segData, 'xBoundarySelected') && ~isempty(segData.xBoundarySelected)
        plot(segData.xBoundarySelected, segData.yBoundarySelected, 'm.', 'MarkerSize', 9, 'DisplayName', 'Selected fit points');
    end

    if isfield(segData, 'detectedValidationBox_scaled') && isfield(segData, 'validationBoxExtendedForAnalysis') && segData.validationBoxExtendedForAnalysis
        drawValidationBox(segData.detectedValidationBox_scaled, [0.65, 0.65, 0.65], 1.5);
    end
    if isfield(segData, 'validationBox_scaled')
        drawValidationBox(segData.validationBox_scaled, [0.1, 0.45, 1.0], 3);
        if isfield(segData, 'validationBoxTolerance_scaled') && segData.validationBoxTolerance_scaled > 0
            drawValidationBox(applyValidationBoxTolerance(segData.validationBox_scaled, segData.validationBoxTolerance_scaled), [1.0, 0.55, 0.0], 2);
        end
    end

    if isfield(segData, 'cx_scaled') && isfield(segData, 'cy_scaled') && isfield(segData, 'r_scaled')
        thetaCircle = linspace(0, 2*pi, 300);
        plot(segData.cx_scaled + segData.r_scaled*cos(thetaCircle), ...
             segData.cy_scaled + segData.r_scaled*sin(thetaCircle), ...
             'y-', 'LineWidth', 2.5, 'DisplayName', 'Drum');
        if isfield(segData, 'drumTolerance_scaled')
            usableRadius = max(segData.r_scaled - segData.drumTolerance_scaled, 1);
            plot(segData.cx_scaled + usableRadius*cos(thetaCircle), ...
                 segData.cy_scaled + usableRadius*sin(thetaCircle), ...
                 'c--', 'LineWidth', 2.0, 'DisplayName', 'Drum tolerance');
        end
        zoomAxesToDrumDiameter(gca, segData.cx_scaled, segData.cy_scaled, segData.r_scaled, size(frame));
    end

    if isfield(segData, 'xBoundarySelected') && ~isempty(segData.xBoundarySelected) && isfield(segData, 'm')
        xLine = linspace(min(segData.xBoundarySelected)-50, max(segData.xBoundarySelected)+50, 100);
        yLine = segData.m * xLine + (mean(segData.yBoundarySelected) - segData.m * mean(segData.xBoundarySelected));
        plot(xLine, yLine, 'r-', 'LineWidth', 3.0, 'DisplayName', sprintf('Fitted material line %.2f deg', angle));
    end

    if isfield(segData, 'pRef_scaled')
        xRef = linspace(1, size(frame, 2), 200);
        yRef = polyval(segData.pRef_scaled, xRef);
        plot(xRef, yRef, 'w--', 'LineWidth', 2.0, 'DisplayName', 'Reference line');
    end

    alignmentText = '';
    if isfield(segData, 'validationBoxAlignmentInfo')
        alignmentInfo = segData.validationBoxAlignmentInfo;
        alignmentText = sprintf(' | plane diff %.2f deg | plane x %.1f', ...
                                alignmentInfo.angleDifferenceDegrees, alignmentInfo.planeCenterX);
    end
    if isfield(segData, 'validationBoxExtendedForAnalysis') && segData.validationBoxExtendedForAnalysis && ...
       isfield(segData, 'validationBoxLengthExtension_scaled')
        alignmentText = sprintf('%s | extended box %.1f px', alignmentText, segData.validationBoxLengthExtension_scaled);
    end
    title(sprintf('%s | angle %.2f deg | box density %.1f%%%s', imageName, angle, density, alignmentText), 'Interpreter', 'none');
    legend('Location', 'best');
    hold off;

    print(fig, overlayFile, '-dpng', '-r200');
    close(fig);

    metadata = struct();
    metadata.imageName = imageName;
    metadata.angleDegrees = angle;
    metadata.boxDensityPercent = density;
    metadata.processingTimeSeconds = processingTimeSeconds;
    if isfield(segData, 'validationBoxAlignmentInfo')
        metadata.alignmentInfo = segData.validationBoxAlignmentInfo;
    end
    if isfield(segData, 'validationBox_scaled')
        metadata.validationBox = segData.validationBox_scaled;
    end
    if isfield(segData, 'detectedValidationBox_scaled')
        metadata.detectedValidationBox = segData.detectedValidationBox_scaled;
    end
    if isfield(segData, 'validationBoxExtendedForAnalysis')
        metadata.validationBoxExtendedForAnalysis = segData.validationBoxExtendedForAnalysis;
    end
    if isfield(segData, 'validationBoxLengthExtension_scaled')
        metadata.validationBoxLengthExtensionPixels = segData.validationBoxLengthExtension_scaled;
    end
    if isfield(segData, 'validationBoxTolerance_scaled')
        metadata.validationBoxTolerancePixels = segData.validationBoxTolerance_scaled;
    end
    if isfield(segData, 'drumTolerance_scaled')
        metadata.drumTolerancePixels = segData.drumTolerance_scaled;
    end
    metadata.exportedAt = datestr(now, 'yyyy-mm-dd HH:MM:SS');
    save(metadataMatFile, 'metadata');

    fid = fopen(metadataFile, 'w');
    if fid ~= -1
        fprintf(fid, 'Validation alignment instance\n');
        fprintf(fid, 'Image: %s\n', imageName);
        fprintf(fid, 'Angle: %.6f degrees\n', angle);
        fprintf(fid, 'Box density: %.6f %%\n', density);
        fprintf(fid, 'Processing time: %.6f seconds\n', processingTimeSeconds);
        if isfield(metadata, 'alignmentInfo')
            fprintf(fid, 'Plane angle: %.6f degrees\n', metadata.alignmentInfo.planeAngleDegrees);
            fprintf(fid, 'Reference angle: %.6f degrees\n', metadata.alignmentInfo.referenceAngleDegrees);
            fprintf(fid, 'Plane-reference difference: %.6f degrees\n', metadata.alignmentInfo.angleDifferenceDegrees);
            fprintf(fid, 'Plane center: (%.6f, %.6f) px\n', metadata.alignmentInfo.planeCenterX, metadata.alignmentInfo.planeCenterY);
            fprintf(fid, 'Alignment reason: %s\n', metadata.alignmentInfo.reason);
        end
        if isfield(metadata, 'validationBoxExtendedForAnalysis')
            fprintf(fid, 'Analysis box extended: %d\n', metadata.validationBoxExtendedForAnalysis);
        end
        if isfield(metadata, 'validationBoxLengthExtensionPixels')
            fprintf(fid, 'Analysis box length extension: %.6f px\n', metadata.validationBoxLengthExtensionPixels);
        end
        if isfield(metadata, 'validationBoxTolerancePixels')
            fprintf(fid, 'Validation box tolerance: %.6f px\n', metadata.validationBoxTolerancePixels);
        end
        if isfield(metadata, 'drumTolerancePixels')
            fprintf(fid, 'Drum tolerance: %.6f px\n', metadata.drumTolerancePixels);
        end
        fprintf(fid, 'Overlay image: %s\n', overlayFile);
        fprintf(fid, 'Exported at: %s\n', metadata.exportedAt);
        fclose(fid);
    end
end

function instanceDir = exportSlipValidationInstance(frame, imageName, slipData, exportRoot, rotationIndex)
    if isempty(exportRoot)
        exportRoot = pwd;
    end
    if ~isfolder(exportRoot)
        mkdir(exportRoot);
    end

    [~, imageBaseName, ~] = fileparts(imageName);
    safeImageName = makeSafeFileName(imageBaseName);
    instanceDir = fullfile(exportRoot, sprintf('%03d_slip_%s', rotationIndex, safeImageName));
    suffix = 1;
    baseInstanceDir = instanceDir;
    while isfolder(instanceDir)
        suffix = suffix + 1;
        instanceDir = sprintf('%s_%d', baseInstanceDir, suffix);
    end
    mkdir(instanceDir);

    overlayFile = fullfile(instanceDir, 'validation_slip_overlay.png');
    metadataFile = fullfile(instanceDir, 'validation_slip_metadata.txt');
    metadataMatFile = fullfile(instanceDir, 'validation_slip_metadata.mat');

    fig = figure('Visible', 'off', 'Units', 'pixels', 'Position', [100, 100, 1400, 1000]);
    imshow(frame);
    hold on;

    if isfield(slipData, 'materialBoundaryX') && ~isempty(slipData.materialBoundaryX)
        plot(slipData.materialBoundaryX, slipData.materialBoundaryY, '.', ...
             'Color', [1.0, 0.78, 0.15], 'MarkerSize', 4, 'DisplayName', 'Segmented material boundary');
    end
    if isfield(slipData, 'materialInsideBoundaryX') && ~isempty(slipData.materialInsideBoundaryX)
        plot(slipData.materialInsideBoundaryX, slipData.materialInsideBoundaryY, 'r.', ...
             'MarkerSize', 8, 'DisplayName', 'Material still inside box');
    end

    if isfield(slipData, 'validationBox_scaled')
        drawValidationBox(slipData.validationBox_scaled, [0.1, 0.45, 1.0], 3);
        if isfield(slipData, 'validationBoxTolerance_scaled') && slipData.validationBoxTolerance_scaled > 0
            drawValidationBox(applyValidationBoxTolerance(slipData.validationBox_scaled, slipData.validationBoxTolerance_scaled), [1.0, 0.55, 0.0], 2);
        end
    end

    if isfield(slipData, 'cx_scaled') && isfield(slipData, 'cy_scaled') && isfield(slipData, 'r_scaled')
        thetaCircle = linspace(0, 2*pi, 300);
        plot(slipData.cx_scaled + slipData.r_scaled*cos(thetaCircle), ...
             slipData.cy_scaled + slipData.r_scaled*sin(thetaCircle), ...
             'y-', 'LineWidth', 2.5, 'DisplayName', 'Drum');
        if isfield(slipData, 'drumTolerance_scaled')
            usableRadius = max(slipData.r_scaled - slipData.drumTolerance_scaled, 1);
            plot(slipData.cx_scaled + usableRadius*cos(thetaCircle), ...
                 slipData.cy_scaled + usableRadius*sin(thetaCircle), ...
                 'c--', 'LineWidth', 2.0, 'DisplayName', 'Drum tolerance');
        end
        zoomAxesToDrumDiameter(gca, slipData.cx_scaled, slipData.cy_scaled, slipData.r_scaled, size(frame));
    end

    if isfield(slipData, 'pRef_scaled')
        xRef = linspace(1, size(frame, 2), 200);
        yRef = polyval(slipData.pRef_scaled, xRef);
        plot(xRef, yRef, 'w--', 'LineWidth', 2.0, 'DisplayName', 'Reference line');
    end

    title(sprintf('%s | rotation %d | slip angle %.2f deg | in box %d px (%.4f)', ...
          imageName, rotationIndex, slipData.slipAngleDegrees, ...
          slipData.materialPixelsInBox, slipData.materialFractionInBox), 'Interpreter', 'none');
    legend('Location', 'best');
    hold off;

    print(fig, overlayFile, '-dpng', '-r200');
    close(fig);

    metadata = slipData;
    metadata.imageName = imageName;
    metadata.rotation = rotationIndex;
    metadata.overlayFile = overlayFile;
    metadata.exportedAt = datestr(now, 'yyyy-mm-dd HH:MM:SS');
    save(metadataMatFile, 'metadata');

    fid = fopen(metadataFile, 'w');
    if fid ~= -1
        fprintf(fid, 'Validation slip instance\n');
        fprintf(fid, 'Rotation: %d\n', rotationIndex);
        fprintf(fid, 'Image: %s\n', imageName);
        if isfield(slipData, 'timestampSeconds')
            fprintf(fid, 'Timestamp: %.6f seconds\n', slipData.timestampSeconds);
        end
        fprintf(fid, 'Slip angle: %.6f degrees\n', slipData.slipAngleDegrees);
        fprintf(fid, 'Plane angle: %.6f degrees\n', slipData.planeAngleDegrees);
        fprintf(fid, 'Reference angle: %.6f degrees\n', slipData.referenceAngleDegrees);
        fprintf(fid, 'Material pixels total: %d\n', slipData.materialPixelsTotal);
        fprintf(fid, 'Material pixels in box: %d\n', slipData.materialPixelsInBox);
        fprintf(fid, 'Material fraction in box: %.8f\n', slipData.materialFractionInBox);
        fprintf(fid, 'Slip reason: %s\n', slipData.reason);
        fprintf(fid, 'Overlay image: %s\n', overlayFile);
        fprintf(fid, 'Exported at: %s\n', metadata.exportedAt);
        fclose(fid);
    end
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
    validationBox = [];
    if isfield(segData, 'validationBox_scaled')
        validationBox = segData.validationBox_scaled;
    end
    cx_scaled = segData.cx_scaled;
    cy_scaled = segData.cy_scaled;
    r_scaled = segData.r_scaled;
    pRef_scaled = segData.pRef_scaled;
    validationBox_scaled = [];
    if isfield(segData, 'validationBox_scaled')
        validationBox_scaled = segData.validationBox_scaled;
    end
    
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
    if ~isempty(validationBox_scaled)
        drawValidationBox(validationBox_scaled, [0.1, 0.45, 1.0], 2.5);
    end
    
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
                        'Box Density: %.1f%%\n' ...
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
    validationBox_scaled = [];
    if isfield(segData, 'validationBox_scaled')
        validationBox_scaled = segData.validationBox_scaled;
    end
    
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
    if ~isempty(validationBox_scaled)
        drawValidationBox(validationBox_scaled, [0.1, 0.45, 1.0], 2.5);
    end
    
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
                        'Box density: %.1f%%\n' ...
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
        case {'b', 'blue'}
            label = 'Blue';
            hMin = 0.58; hMax = 0.76; sMin = 0.25; vMin = 0.25;
        otherwise
            label = 'Green';
            hMin = 0.15; hMax = 0.40; sMin = 0.10; vMin = 0.20;
    end
end

%% ========== VALIDATION BOX CALIBRATION TOOL ==========

function [validationBox, hMin, hMax, sMin, vMin, edgeThresholdOut, dilationRadiusOut, closingRadiusOut, accepted] = ...
    improvedValidationBoxCalibrationTool(frame, cx, cy, r, minArea, hMinInit, hMaxInit, sMinInit, vMinInit, ...
                                         edgeThresholdInit, dilationRadiusInit, closingRadiusInit, exportDir, sourceLabel)
    % IMPROVEDVALIDATIONBOXCALIBRATIONTOOL - Tune blue-plane segmentation and preview the derived box.

    if nargin < 13, exportDir = ''; end
    if nargin < 14, sourceLabel = 'validation_box_frame'; end

    Ihsv = rgb2hsv(frame);
    H = Ihsv(:,:,1);

    hMin = hMinInit;
    hMax = hMaxInit;
    sMin = sMinInit;
    vMin = vMinInit;
    edgeThresholdOut = edgeThresholdInit;
    dilationRadiusOut = dilationRadiusInit;
    closingRadiusOut = closingRadiusInit;
    validationBox = [];
    currentValidationBox = [];
    currentPlaneMask = [];
    currentEdgeMask = [];
    currentBoundaryX = [];
    currentBoundaryY = [];
    accepted = false;

    fig = figure('Name', 'Validation Box Calibration - Blue Plane', 'NumberTitle', 'off', ...
                 'Position', [10, 50, 1920, 1080], 'CloseRequestFcn', @fig_close);

    ax_original = subplot(3, 2, 1);
    ax_mask = subplot(3, 2, 2);
    ax_edge = subplot(3, 2, 3);
    ax_preview = subplot(3, 2, 4);
    ax_hist_hue = subplot(3, 2, 5);
    ax_info = subplot(3, 2, 6);

    uicontrol(fig, 'Style', 'text', 'Position', [20, 210, 60, 20], 'String', 'H Min:', 'HorizontalAlignment', 'left', 'FontWeight', 'bold');
    slider_h_min = uicontrol(fig, 'Style', 'slider', 'Position', [90, 210, 200, 20], ...
        'Min', 0, 'Max', 1, 'Value', hMinInit, 'Callback', @(h,e) on_slider_changed());
    txt_hmin = uicontrol(fig, 'Style', 'edit', 'Position', [300, 210, 60, 20], 'String', sprintf('%.3f', hMinInit), 'Enable', 'off');

    uicontrol(fig, 'Style', 'text', 'Position', [20, 180, 60, 20], 'String', 'H Max:', 'HorizontalAlignment', 'left', 'FontWeight', 'bold');
    slider_h_max = uicontrol(fig, 'Style', 'slider', 'Position', [90, 180, 200, 20], ...
        'Min', 0, 'Max', 1, 'Value', hMaxInit, 'Callback', @(h,e) on_slider_changed());
    txt_hmax = uicontrol(fig, 'Style', 'edit', 'Position', [300, 180, 60, 20], 'String', sprintf('%.3f', hMaxInit), 'Enable', 'off');

    uicontrol(fig, 'Style', 'text', 'Position', [20, 150, 60, 20], 'String', 'S Min:', 'HorizontalAlignment', 'left', 'FontWeight', 'bold');
    slider_s_min = uicontrol(fig, 'Style', 'slider', 'Position', [90, 150, 200, 20], ...
        'Min', 0, 'Max', 1, 'Value', sMinInit, 'Callback', @(h,e) on_slider_changed());
    txt_smin = uicontrol(fig, 'Style', 'edit', 'Position', [300, 150, 60, 20], 'String', sprintf('%.3f', sMinInit), 'Enable', 'off');

    uicontrol(fig, 'Style', 'text', 'Position', [20, 120, 60, 20], 'String', 'V Min:', 'HorizontalAlignment', 'left', 'FontWeight', 'bold');
    slider_v_min = uicontrol(fig, 'Style', 'slider', 'Position', [90, 120, 200, 20], ...
        'Min', 0, 'Max', 1, 'Value', vMinInit, 'Callback', @(h,e) on_slider_changed());
    txt_vmin = uicontrol(fig, 'Style', 'edit', 'Position', [300, 120, 60, 20], 'String', sprintf('%.3f', vMinInit), 'Enable', 'off');

    uicontrol(fig, 'Style', 'text', 'Position', [380, 210, 120, 20], 'String', 'PLANE EDGE:', 'HorizontalAlignment', 'left', 'FontWeight', 'bold', 'ForegroundColor', 'blue');

    uicontrol(fig, 'Style', 'text', 'Position', [380, 180, 120, 20], 'String', 'Canny Threshold:', 'HorizontalAlignment', 'left', 'FontWeight', 'bold');
    slider_edge_threshold = uicontrol(fig, 'Style', 'slider', 'Position', [520, 180, 150, 20], ...
        'Min', 0.01, 'Max', 0.5, 'Value', edgeThresholdInit, 'Callback', @(h,e) on_slider_changed());
    txt_edge_threshold = uicontrol(fig, 'Style', 'edit', 'Position', [680, 180, 60, 20], 'String', sprintf('%.3f', edgeThresholdInit), 'Enable', 'off');

    uicontrol(fig, 'Style', 'text', 'Position', [380, 150, 120, 20], 'String', 'Dilation Radius:', 'HorizontalAlignment', 'left', 'FontWeight', 'bold');
    slider_morph_radius = uicontrol(fig, 'Style', 'slider', 'Position', [520, 150, 150, 20], ...
        'Min', 1, 'Max', 5, 'Value', dilationRadiusInit, 'Callback', @(h,e) on_slider_changed());
    txt_morph_radius = uicontrol(fig, 'Style', 'edit', 'Position', [680, 150, 60, 20], 'String', sprintf('%.1f', dilationRadiusInit), 'Enable', 'off');

    uicontrol(fig, 'Style', 'pushbutton', 'Position', [800, 180, 100, 30], ...
        'String', 'Accept', 'FontSize', 12, 'FontWeight', 'bold', 'BackgroundColor', [0.2, 0.8, 0.2], ...
        'Callback', @btn_accept_callback);

    uicontrol(fig, 'Style', 'pushbutton', 'Position', [920, 180, 100, 30], ...
        'String', 'Reject', 'FontSize', 12, 'FontWeight', 'bold', 'BackgroundColor', [0.8, 0.2, 0.2], ...
        'Callback', @btn_reject_callback);

    function updateDisplay()
        hMinVal = get(slider_h_min, 'Value');
        hMaxVal = get(slider_h_max, 'Value');
        sMinVal = get(slider_s_min, 'Value');
        vMinVal = get(slider_v_min, 'Value');
        edgeThresholdVal = get(slider_edge_threshold, 'Value');
        dilationRadiusVal = round(get(slider_morph_radius, 'Value'));
        closingRadiusVal = max(2, 2 * dilationRadiusVal);

        set(txt_hmin, 'String', sprintf('%.3f', hMinVal));
        set(txt_hmax, 'String', sprintf('%.3f', hMaxVal));
        set(txt_smin, 'String', sprintf('%.3f', sMinVal));
        set(txt_vmin, 'String', sprintf('%.3f', vMinVal));
        set(txt_edge_threshold, 'String', sprintf('%.3f', edgeThresholdVal));
        set(txt_morph_radius, 'String', sprintf('%.0f', dilationRadiusVal));

        [currentValidationBox, currentPlaneMask, currentEdgeMask, currentBoundaryX, currentBoundaryY] = ...
            deriveValidationBoxFromPlane(frame, cx, cy, r, minArea, hMinVal, hMaxVal, sMinVal, vMinVal, ...
                                         edgeThresholdVal, dilationRadiusVal, closingRadiusVal);

        axes(ax_original);
        cla;
        imshow(frame);
        zoomAxesToDrumDiameter(ax_original, cx, cy, r, size(frame));
        title('1. Original Image', 'FontSize', 14, 'FontWeight', 'bold');
        hold on;
        thetaCircle = linspace(0, 2*pi, 200);
        plot(cx + r*cos(thetaCircle), cy + r*sin(thetaCircle), 'g-', 'LineWidth', 2, 'DisplayName', 'Drum');
        hold off;

        axes(ax_mask);
        cla;
        imshow(currentPlaneMask);
        zoomAxesToDrumDiameter(ax_mask, cx, cy, r, size(frame));
        colormap(ax_mask, gray);
        title('2. Blue Plane Mask', 'FontSize', 14, 'FontWeight', 'bold');

        axes(ax_edge);
        cla;
        imshow(currentEdgeMask);
        zoomAxesToDrumDiameter(ax_edge, cx, cy, r, size(frame));
        colormap(ax_edge, gray);
        hold on;
        if ~isempty(currentBoundaryX)
            plot(currentBoundaryX, currentBoundaryY, 'r.', 'MarkerSize', 6, 'DisplayName', sprintf('%d edge points', numel(currentBoundaryX)));
        end
        hold off;
        title('3. Segmented Plane Edge', 'FontSize', 14, 'FontWeight', 'bold');

        axes(ax_preview);
        cla;
        imshow(frame);
        zoomAxesToDrumDiameter(ax_preview, cx, cy, r, size(frame));
        title('4. Validation Box Preview', 'FontSize', 14, 'FontWeight', 'bold');
        hold on;
        if ~isempty(currentBoundaryX)
            plot(currentBoundaryX, currentBoundaryY, 'c.', 'MarkerSize', 5, 'DisplayName', 'Plane edge');
        end
        if ~isempty(currentValidationBox)
            drawValidationBox(currentValidationBox, [0.1, 0.45, 1.0], 3);
        end
        plot(cx + r*cos(thetaCircle), cy + r*sin(thetaCircle), 'g-', 'LineWidth', 2, 'DisplayName', 'Drum');
        legend('Location', 'best', 'FontSize', 9);
        hold off;

        axes(ax_hist_hue);
        cla;
        histogram(H(:), 150, 'FaceColor', [0.1, 0.35, 0.9], 'FaceAlpha', 0.7);
        hold on;
        plot([hMinVal hMinVal], ylim, 'r-', 'LineWidth', 3);
        plot([hMaxVal hMaxVal], ylim, 'r-', 'LineWidth', 3);
        hold off;
        xlabel('Hue', 'FontSize', 11);
        ylabel('Frequency', 'FontSize', 11);
        title('5. Hue Distribution', 'FontSize', 14, 'FontWeight', 'bold');
        xlim([0, 1]);

        axes(ax_info);
        cla;
        axis off;

        maskPixels = sum(currentPlaneMask(:));
        [rowsInfo, colsInfo, ~] = size(frame);
        [XInfo, YInfo] = meshgrid(1:colsInfo, 1:rowsInfo);
        drumMaskInfo = sqrt((XInfo - cx).^2 + (YInfo - cy).^2) <= r;
        drumPixels = sum(drumMaskInfo(:));
        coverage = 100 * maskPixels / max(drumPixels, 1);
        edgePixels = sum(currentEdgeMask(:));
        if isempty(currentValidationBox)
            boxText = 'Box: not detected';
            lengthText = 'Length: N/A';
            heightText = 'Height: N/A';
            areaText = 'Area: N/A';
        else
            boxText = sprintf('Box: x=[%.1f, %.1f], y=[%.1f, %.1f]', ...
                              currentValidationBox.xMin, currentValidationBox.xMax, currentValidationBox.yMin, currentValidationBox.yMax);
            lengthText = sprintf('Length: %.1f px', currentValidationBox.width);
            heightText = sprintf('Height: %.1f px (drum radius %.1f px)', currentValidationBox.height, r);
            areaText = sprintf('Area: %.0f px^2', currentValidationBox.areaPixels);
        end

        infoText = sprintf(['VALIDATION BOX STATISTICS\n' ...
                            '===================================\n' ...
                            'Plane mask pixels inside drum: %d\n' ...
                            'Coverage inside drum: %.2f%%\n' ...
                            'Edge pixels: %d\n' ...
                            'Boundary points: %d\n' ...
                            '\n' ...
                            '%s\n%s\n%s\n%s\n' ...
                            '\n' ...
                            'HSV THRESHOLDS\n' ...
                            '-----------------------------------\n' ...
                            'H: [%.3f, %.3f]\n' ...
                            'S: > %.3f\n' ...
                            'V: > %.3f\n' ...
                            '\n' ...
                            'EDGE PARAMETERS\n' ...
                            '-----------------------------------\n' ...
                            'Canny Threshold: %.3f\n' ...
                            'Dilation Radius: %d\n' ...
                            'Closing Radius: %d\n'], ...
                           maskPixels, coverage, edgePixels, numel(currentBoundaryX), ...
                           boxText, lengthText, heightText, areaText, ...
                           hMinVal, hMaxVal, sMinVal, vMinVal, ...
                           edgeThresholdVal, dilationRadiusVal, closingRadiusVal);

        text(0.05, 0.5, infoText, 'FontName', 'Monospaced', 'FontSize', 10, ...
             'VerticalAlignment', 'middle', 'Parent', ax_info);

        drawnow limitrate;
    end

    function on_slider_changed()
        updateDisplay();
    end

    function btn_accept_callback(~, ~)
        updateDisplay();
        if isempty(currentValidationBox)
            errordlg('No valid validation box detected. Adjust the blue-plane segmentation before accepting.', 'Validation box not detected');
            return;
        end

        hMin = get(slider_h_min, 'Value');
        hMax = get(slider_h_max, 'Value');
        sMin = get(slider_s_min, 'Value');
        vMin = get(slider_v_min, 'Value');
        edgeThresholdOut = get(slider_edge_threshold, 'Value');
        dilationRadiusOut = round(get(slider_morph_radius, 'Value'));
        closingRadiusOut = max(2, 2 * dilationRadiusOut);
        validationBox = currentValidationBox;
        accepted = true;

        fprintf('\nValidation box calibration accepted:\n');
        fprintf('  Blue plane HSV: H=[%.3f, %.3f], S>%.3f, V>%.3f\n', hMin, hMax, sMin, vMin);
        fprintf('  Edge threshold: %.3f\n', edgeThresholdOut);
        fprintf('  Box width: %.1f px, height: %.1f px\n\n', validationBox.width, validationBox.height);

        if ~isempty(exportDir)
            try
                exportValidationBoxCalibrationArtifacts(frame, fig, exportDir, sourceLabel, ...
                    hMin, hMax, sMin, vMin, edgeThresholdOut, dilationRadiusOut, closingRadiusOut, ...
                    cx, cy, r, validationBox, currentPlaneMask, currentEdgeMask, currentBoundaryX, currentBoundaryY);
            catch ME
                warning('Could not export validation box calibration artifacts: %s', ME.message);
            end
        end

        closeCalibrationFigure();
    end

    function btn_reject_callback(~, ~)
        accepted = false;
        closeCalibrationFigure();
    end

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

    fprintf('\nVALIDATION BOX CALIBRATION TOOL\n');
    fprintf('Adjust the blue-plane HSV and edge sliders until the preview box follows the blue plane length.\n');
    fprintf('The box height is one calibrated drum radius and extends toward the drum center.\n\n');

    updateDisplay();
    uiwait(fig);
end

function exportValidationBoxCalibrationArtifacts(frame, calibrationFig, exportFolder, sourceLabel, ...
    hMin, hMax, sMin, vMin, edgeThreshold, dilationRadius, closingRadius, cx, cy, r, validationBox, planeMask, edgeMask, xBoundary, yBoundary)
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
            imwrite(windowFrame.cdata, fullfile(runExportFolder, '01_validation_box_window.png'));
        catch
            print(calibrationFig, fullfile(runExportFolder, '01_validation_box_window.png'), '-dpng', '-r200');
        end
    end

    values = struct();
    values.sourceLabel = sourceLabel;
    values.hMin = hMin;
    values.hMax = hMax;
    values.sMin = sMin;
    values.vMin = vMin;
    values.edgeThreshold = edgeThreshold;
    values.segmentationDilationRadius = dilationRadius;
    values.segmentationClosingRadius = closingRadius;
    values.drumCenterX = cx;
    values.drumCenterY = cy;
    values.drumRadiusPixels = r;
    values.validationBox = validationBox;
    values.planeMaskPixels = sum(planeMask(:));
    values.edgePixels = sum(edgeMask(:));
    values.boundaryPoints = numel(xBoundary);
    values.exportedAt = datestr(now, 'yyyy-mm-dd HH:MM:SS');

    parameterNames = { ...
        'source_label'; 'h_min'; 'h_max'; 's_min'; 'v_min'; ...
        'edge_threshold'; 'segmentation_dilation_radius'; 'segmentation_closing_radius'; ...
        'drum_center_x'; 'drum_center_y'; 'drum_radius_pixels'; ...
        'box_x_min'; 'box_x_max'; 'box_y_min'; 'box_y_max'; 'box_width'; 'box_height'; 'box_area_pixels'; ...
        'plane_mask_pixels'; 'edge_pixels'; 'boundary_points'; 'exported_at'};
    parameterValues = { ...
        char(sourceLabel); sprintf('%.6f', hMin); sprintf('%.6f', hMax); ...
        sprintf('%.6f', sMin); sprintf('%.6f', vMin); sprintf('%.6f', edgeThreshold); ...
        sprintf('%d', dilationRadius); sprintf('%d', closingRadius); sprintf('%.6f', cx); ...
        sprintf('%.6f', cy); sprintf('%.6f', r); sprintf('%.6f', validationBox.xMin); ...
        sprintf('%.6f', validationBox.xMax); sprintf('%.6f', validationBox.yMin); sprintf('%.6f', validationBox.yMax); ...
        sprintf('%.6f', validationBox.width); sprintf('%.6f', validationBox.height); sprintf('%.0f', validationBox.areaPixels); ...
        sprintf('%d', values.planeMaskPixels); sprintf('%d', values.edgePixels); sprintf('%d', values.boundaryPoints); values.exportedAt};
    validationTable = table(parameterNames, parameterValues, 'VariableNames', {'Parameter', 'Value'});
    writetable(validationTable, fullfile(runExportFolder, 'validation_box_values.csv'));
    save(fullfile(runExportFolder, 'validation_box_values.mat'), 'values');

    fid = fopen(fullfile(runExportFolder, 'validation_box_values.txt'), 'w');
    if fid ~= -1
        fprintf(fid, 'Validation box calibration export\n');
        fprintf(fid, 'Source: %s\n\n', sourceLabel);
        fprintf(fid, 'Blue plane HSV thresholds\n');
        fprintf(fid, '  H: [%.6f, %.6f]\n', hMin, hMax);
        fprintf(fid, '  S: > %.6f\n', sMin);
        fprintf(fid, '  V: > %.6f\n\n', vMin);
        fprintf(fid, 'Box definition\n');
        fprintf(fid, '  x: [%.6f, %.6f]\n', validationBox.xMin, validationBox.xMax);
        fprintf(fid, '  y: [%.6f, %.6f]\n', validationBox.yMin, validationBox.yMax);
        fprintf(fid, '  width: %.6f px\n', validationBox.width);
        fprintf(fid, '  height: %.6f px\n', validationBox.height);
        fprintf(fid, '  requested height/drum radius: %.6f px\n', r);
        fclose(fid);
    end

    figPreview = figure('Visible', 'off', 'Units', 'inches', 'Position', [0, 0, 10, 8]);
    imshow(frame);
    hold on;
    if ~isempty(xBoundary)
        plot(xBoundary, yBoundary, 'c.', 'MarkerSize', 5, 'DisplayName', 'Blue plane edge');
    end
    thetaCircle = linspace(0, 2*pi, 300);
    plot(cx + r*cos(thetaCircle), cy + r*sin(thetaCircle), 'g-', 'LineWidth', 2, 'DisplayName', 'Drum');
    drawValidationBox(validationBox, [0.1, 0.45, 1.0], 3);
    legend('Location', 'best');
    title('Accepted validation box preview', 'Interpreter', 'none');
    printCalibrationFigure(figPreview, fullfile(runExportFolder, '02_validation_box_preview.png'), 200);
    close(figPreview);

    figMask = figure('Visible', 'off', 'Units', 'inches', 'Position', [0, 0, 8, 5.5]);
    imshow(planeMask);
    colormap(gca, gray);
    title('Accepted blue plane mask');
    printCalibrationFigure(figMask, fullfile(runExportFolder, '03_blue_plane_mask.png'), 200);
    close(figMask);

    figEdge = figure('Visible', 'off', 'Units', 'inches', 'Position', [0, 0, 8, 5.5]);
    imshow(edgeMask);
    colormap(gca, gray);
    hold on;
    if ~isempty(xBoundary)
        plot(xBoundary, yBoundary, 'r.', 'MarkerSize', 5);
    end
    hold off;
    title('Accepted blue plane edge');
    printCalibrationFigure(figEdge, fullfile(runExportFolder, '04_blue_plane_edge.png'), 200);
    close(figEdge);

    fprintf('Validation box calibration export saved to: %s\n', runExportFolder);
end

%% ========== IMPROVED COLOR CALIBRATION TOOL ==========

function [hMin, hMax, sMin, vMin, edgeThresholdOut, dilationRadiusOut, closingRadiusOut, drumToleranceOut, validationBoxToleranceOut, accepted] = improvedColorCalibrationTool(frame, mRef, cx, cy, r, minArea, smoothWindow, drumTolerance, yLower, yUpper, varargin)
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
    hMin = hMin_val;
    hMax = hMax_val;
    sMin = sMin_val;
    vMin = vMin_val;
    dilationRadiusOut = morphRadius;
    closingRadiusOut = closingRadius;
    drumToleranceOut = drumTolerance;
    validationBoxToleranceOut = 0;

    calibrationExportDir = '';
    calibrationSourceLabel = 'calibration_frame';
    if numel(varargin) >= 9 && (ischar(varargin{9}) || isstring(varargin{9}))
        calibrationExportDir = char(varargin{9});
    end
    if numel(varargin) >= 10 && (ischar(varargin{10}) || isstring(varargin{10}))
        calibrationSourceLabel = char(varargin{10});
    end
    analysisBox = [];
    if numel(varargin) >= 11 && isstruct(varargin{11})
        analysisBox = varargin{11};
    end
    validationBoxTolerance = 0;
    if numel(varargin) >= 12 && isnumeric(varargin{12})
        validationBoxTolerance = varargin{12};
    end
    validationBoxToleranceOut = validationBoxTolerance;
    
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

    % Drum Tolerance
    drumToleranceSliderMax = max([1, min(r, max(100, 3 * max(drumTolerance, 1)))]);
    uicontrol(fig, 'Style', 'text', 'Position', [380, 120, 120, 20], 'String', 'Drum Tolerance:', 'HorizontalAlignment', 'left', 'FontWeight', 'bold');
    slider_drum_tolerance = uicontrol(fig, 'Style', 'slider', 'Position', [520, 120, 150, 20], ...
        'Min', 0, 'Max', drumToleranceSliderMax, 'Value', min(drumTolerance, drumToleranceSliderMax), 'Callback', @(h,e) on_slider_changed());
    txt_drum_tolerance = uicontrol(fig, 'Style', 'edit', 'Position', [680, 120, 60, 20], 'String', sprintf('%.1f', drumTolerance), 'Enable', 'off');

    % Validation Box Tolerance
    if isempty(analysisBox)
        boxToleranceSliderMax = 1;
        boxToleranceInitial = 0;
    else
        boxToleranceSliderMax = max(1, floor(min(analysisBox.width, analysisBox.height) / 2 - 1));
        boxToleranceInitial = min(validationBoxTolerance, boxToleranceSliderMax);
    end
    uicontrol(fig, 'Style', 'text', 'Position', [380, 90, 120, 20], 'String', 'Box Tolerance:', 'HorizontalAlignment', 'left', 'FontWeight', 'bold');
    slider_box_tolerance = uicontrol(fig, 'Style', 'slider', 'Position', [520, 90, 150, 20], ...
        'Min', 0, 'Max', boxToleranceSliderMax, 'Value', boxToleranceInitial, 'Callback', @(h,e) on_slider_changed());
    txt_box_tolerance = uicontrol(fig, 'Style', 'edit', 'Position', [680, 90, 60, 20], 'String', sprintf('%.1f', boxToleranceInitial), 'Enable', 'off');
    
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
        drumToleranceCurrent = get(slider_drum_tolerance, 'Value');
        boxToleranceCurrent = get(slider_box_tolerance, 'Value');
        
        % Update display values
        set(txt_hmin, 'String', sprintf('%.3f', hMin_val));
        set(txt_hmax, 'String', sprintf('%.3f', hMax_val));
        set(txt_smin, 'String', sprintf('%.3f', sMin_val));
        set(txt_vmin, 'String', sprintf('%.3f', vMin_val));
        set(txt_edge_threshold, 'String', sprintf('%.3f', edgeThreshold));
        set(txt_morph_radius, 'String', sprintf('%.0f', morphRadius));
        set(txt_drum_tolerance, 'String', sprintf('%.1f', drumToleranceCurrent));
        set(txt_box_tolerance, 'String', sprintf('%.1f', boxToleranceCurrent));
        
        % ===== PANEL 1: Original Image =====
        axes(ax_original);
        cla;
        imshow(frame);
        zoomAxesToDrumDiameter(ax_original, cx, cy, r, size(frame));
        title('1. Original Image', 'FontSize', 14, 'FontWeight', 'bold');
        
        % ===== COLOR SEGMENTATION =====
        greenMask = createColorSegmentationMask(frame, hMin_val, hMax_val, sMin_val, vMin_val, ...
                                                morphRadius, closingRadius, max(minArea/2, 50));
        
        % ===== PANEL 2: Color Detection Mask =====
        axes(ax_mask);
        cla;
        imshow(greenMask);
        zoomAxesToDrumDiameter(ax_mask, cx, cy, r, size(frame));
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
            zoomAxesToDrumDiameter(ax_edge, cx, cy, r, size(frame));
            colormap(ax_edge, gray);
            hold on;
            if ~isempty(xBoundary)
                plot(xBoundary, yBoundary, 'r.', 'MarkerSize', 6, 'DisplayName', sprintf('%d boundary points', numel(xBoundary)));
            end
            hold off;
            title('3. Boundary Points', 'FontSize', 14, 'FontWeight', 'bold');
            
            if numel(xBoundary) > 20
                if isempty(analysisBox)
                    [xBoundaryFiltered, yBoundaryFiltered] = filterBoundaryPointsWithinDrum(xBoundary, yBoundary, cx, cy, r, drumToleranceCurrent);
                else
                    [xBoundaryFiltered, yBoundaryFiltered] = filterBoundaryPointsWithinValidationBox(xBoundary, yBoundary, analysisBox, boxToleranceCurrent);
                    [xBoundaryFiltered, yBoundaryFiltered] = filterBoundaryPointsWithinDrum(xBoundaryFiltered, yBoundaryFiltered, cx, cy, r, drumToleranceCurrent);
                end

                if numel(xBoundaryFiltered) > 20
                    if isempty(analysisBox)
                        [xSurface, ySurface] = selectFreeSurfacePoints(xBoundaryFiltered, yBoundaryFiltered, cx, cy, r, smoothWindow, yLower, yUpper);
                    else
                        [xSurface, ySurface] = selectFreeSurfacePointsInValidationBox(xBoundaryFiltered, yBoundaryFiltered, applyValidationBoxTolerance(analysisBox, boxToleranceCurrent), smoothWindow, yLower, yUpper);
                    end
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
            zoomAxesToDrumDiameter(ax_edge, cx, cy, r, size(frame));
            title('3. Detected Edges', 'FontSize', 14, 'FontWeight', 'bold');
        end
        
        % ===== PANEL 4: Boundary Points Preview =====
        axes(ax_preview_boundary);
        cla;
        imshow(frame);
        zoomAxesToDrumDiameter(ax_preview_boundary, cx, cy, r, size(frame));
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
        usableRadius = max(r - drumToleranceCurrent, 1);
        plot(cx + usableRadius * cos(theta_circ), cy + usableRadius * sin(theta_circ), ...
             'c--', 'LineWidth', 2, 'DisplayName', 'Drum tolerance');
        if ~isempty(analysisBox)
            drawValidationBox(analysisBox, [0.1, 0.45, 1.0], 2.5);
            if boxToleranceCurrent > 0
                drawValidationBox(applyValidationBoxTolerance(analysisBox, boxToleranceCurrent), [1.0, 0.55, 0.0], 2.0);
            end
        end
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
                            'Closing Radius: %d\n' ...
                            'Drum Tolerance: %.1f px\n' ...
                            'Box Tolerance: %.1f px\n'], ...
                           greenPixels, coverage, edgePixels, boundaryNote, ...
                           numel(xBoundaryFiltered), numel(xBoundarySelected), angleStr, ...
                           hMin_val, hMax_val, sMin_val, vMin_val, ...
                           edgeThreshold, morphRadius, closingRadius, drumToleranceCurrent, boxToleranceCurrent);
        
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
        drumToleranceOut = get(slider_drum_tolerance, 'Value');
        validationBoxToleranceOut = get(slider_box_tolerance, 'Value');
        accepted = true;
        
        fprintf('\n✓ Calibration accepted with values:\n');
        fprintf('  H: %.3f - %.3f\n', hMin, hMax);
        fprintf('  S: > %.3f\n', sMin);
        fprintf('  V: > %.3f\n', vMin);
        fprintf('  Edge threshold: %.3f\n', edgeThresholdOut);
        fprintf('  Segmentation morphology: dilation=%d, closing=%d\n', dilationRadiusOut, closingRadiusOut);
        fprintf('  Drum tolerance: %.1f px\n\n', drumToleranceOut);
        fprintf('  Validation box tolerance: %.1f px\n\n', validationBoxToleranceOut);

        if ~isempty(calibrationExportDir)
            updateDisplay();
            drawnow;
            try
                exportColorCalibrationArtifacts(frame, fig, calibrationExportDir, calibrationSourceLabel, colorLabel, ...
                                                hMin, hMax, sMin, vMin, edgeThresholdOut, dilationRadiusOut, closingRadiusOut, ...
                                                mRef, cx, cy, r, minArea, smoothWindow, drumToleranceOut, yLower, yUpper, analysisBox, validationBoxToleranceOut);
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
    fprintf('  • Adjust Drum Tolerance to exclude edge points near the drum wall\n');
    fprintf('  • Adjust Box Tolerance to exclude edge points near or outside the validation box boundary\n');
    fprintf('  • Watch the 6 panels for real-time feedback\n');
    fprintf('  • Check the angle estimate and boundary points\n');
    fprintf('  • Click Accept to use these settings\n\n');
    
    updateDisplay();
    uiwait(fig);
end

%% ========== COLOR CALIBRATION EXPORT FUNCTION ==========

function exportColorCalibrationArtifacts(frame, calibrationFig, exportFolder, sourceLabel, colorLabel, ...
                                         hMin, hMax, sMin, vMin, edgeThreshold, dilationRadius, closingRadius, ...
                                         mRef, cx, cy, r, minArea, smoothWindow, drumTolerance, yLower, yUpper, varargin)
    % EXPORTCOLORCALIBRATIONARTIFACTS - Save accepted calibration preview and final thresholds
    analysisBox = [];
    if ~isempty(varargin) && isstruct(varargin{1})
        analysisBox = varargin{1};
    end
    validationBoxTolerance = 0;
    if numel(varargin) >= 2 && isnumeric(varargin{2})
        validationBoxTolerance = varargin{2};
    end

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
            if isempty(analysisBox)
                [xBoundaryFiltered, yBoundaryFiltered] = filterBoundaryPointsWithinDrum(xBoundary, yBoundary, cx, cy, r, drumTolerance);
            else
                [xBoundaryFiltered, yBoundaryFiltered] = filterBoundaryPointsWithinValidationBox(xBoundary, yBoundary, analysisBox, validationBoxTolerance);
                [xBoundaryFiltered, yBoundaryFiltered] = filterBoundaryPointsWithinDrum(xBoundaryFiltered, yBoundaryFiltered, cx, cy, r, drumTolerance);
            end
            if numel(xBoundaryFiltered) > 20
                if isempty(analysisBox)
                    [xSurface, ySurface] = selectFreeSurfacePoints(xBoundaryFiltered, yBoundaryFiltered, cx, cy, r, smoothWindow, yLower, yUpper);
                else
                    [xSurface, ySurface] = selectFreeSurfacePointsInValidationBox(xBoundaryFiltered, yBoundaryFiltered, applyValidationBoxTolerance(analysisBox, validationBoxTolerance), smoothWindow, yLower, yUpper);
                end
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
    values.validationBoxTolerance = validationBoxTolerance;
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
        'min_area'; 'smooth_window'; 'drum_tolerance'; 'validation_box_tolerance'; 'y_lower'; 'y_upper'; ...
        'mask_pixels'; 'mask_coverage_percent'; 'edge_pixels'; 'boundary_points'; ...
        'filtered_boundary_points'; 'selected_boundary_points'; 'preview_angle_degrees'; ...
        'reference_slope'; 'drum_center_x'; 'drum_center_y'; 'drum_radius_pixels'; 'exported_at'};
    parameterValues = { ...
        char(sourceLabel); char(colorLabel); sprintf('%.6f', hMin); sprintf('%.6f', hMax); ...
        sprintf('%.6f', sMin); sprintf('%.6f', vMin); sprintf('%.6f', edgeThreshold); ...
        sprintf('%d', dilationRadius); sprintf('%d', closingRadius); sprintf('%.6f', minArea); ...
        sprintf('%.6f', smoothWindow); sprintf('%.6f', drumTolerance); sprintf('%.6f', validationBoxTolerance); sprintf('%.6f', yLower); ...
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
        fprintf(fid, '  Closing radius: %d\n', closingRadius);
        fprintf(fid, '  Drum tolerance: %.6f px\n', drumTolerance);
        fprintf(fid, '  Validation box tolerance: %.6f px\n\n', validationBoxTolerance);
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
    usableRadius = max(r - drumTolerance, 1);
    plot(cx + usableRadius*cos(thetaCircle), cy + usableRadius*sin(thetaCircle), 'c--', 'LineWidth', 2, 'DisplayName', 'Drum tolerance');
    if ~isempty(analysisBox)
        drawValidationBox(analysisBox, [0.1, 0.45, 1.0], 2.5);
        if validationBoxTolerance > 0
            drawValidationBox(applyValidationBoxTolerance(analysisBox, validationBoxTolerance), [1.0, 0.55, 0.0], 2.0);
        end
    end
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
    if ~isempty(validationBox)
        drawValidationBox(validationBox, [0.1, 0.45, 1.0], 3);
    end
    
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
    if ~isempty(validationBox)
        drawValidationBox(validationBox, [0.1, 0.45, 1.0], 2.5);
    end
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
        'BOX DENSITY\n' ...
        '─────────────────────────────────────\n' ...
        'Box density: %.2f%%\n\n' ...
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

function overlayFile = exportInitialFrameDrumOverlay(frame, videoFile, runIdx, runCount, pRef, mRef, cx, cy, r, diameterTolerance, validationBox, videoTimeWindowMode, analyzeLastSeconds, analysisStartSeconds, analysisDurationSeconds, startTime, endTime, videoDuration, exportFolder)
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

    if ~isempty(validationBox)
        drawValidationBox(validationBox, [0.1, 0.45, 1.0], 3);
    end

    x_ref = linspace(1, size(frame, 2), 200);
    y_ref = polyval(pRef, x_ref);
    plot(x_ref, y_ref, 'w--', 'LineWidth', 2.5, 'DisplayName', 'Reference line');

    title(sprintf('Initial Frame Drum Overlay: %s', videoBaseName), 'Interpreter', 'none', 'FontSize', 14, 'FontWeight', 'bold');
    windowDescription = describeVideoTimeWindow(videoTimeWindowMode, analyzeLastSeconds, analysisStartSeconds, analysisDurationSeconds);
    timeText = sprintf('Video %d/%d | analyzed window: %.3f s to %.3f s of %.3f s | %s', ...
                       runIdx, runCount, startTime, endTime, videoDuration, windowDescription);

    if isempty(validationBox)
        boxText = 'Validation box: not defined';
    else
        boxText = sprintf('Validation box: width=%.1f px | height=%.1f px | x=[%.1f, %.1f] | y=[%.1f, %.1f]', ...
                          validationBox.width, validationBox.height, validationBox.xMin, validationBox.xMax, validationBox.yMin, validationBox.yMax);
    end
    infoText = sprintf('%s\nCenter=(%.1f, %.1f) px | Diameter=%.1f px | diameter_tolerance=%.1f px | reference slope=%.6f\n%s', ...
                       timeText, cx, cy, 2*r, diameterTolerance, mRef, boxText);
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
    validationBox = [];
    if numel(varargin) >= 8 && isstruct(varargin{8})
        validationBox = varargin{8};
    end
    validationBoxTolerance = 0;
    if numel(varargin) >= 9 && isnumeric(varargin{9})
        validationBoxTolerance = varargin{9};
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
        
        if isempty(validationBox)
            % Calculate angle and density in the drum circle.
            [theta_s, ~, ~, ~, ~, ~] = calculateFrameAngle(frameScaled, mRef_s, cx_s, cy_s, r_s, ...
                        minArea, smoothWindow, drumTolerance_s, yLower, yUpper, ...
                        hMin, hMax, sMin, vMin, edgeThreshold, dilationRadius, closingRadius);
            density_s = calculateDensity(frameScaled, cx_s, cy_s, r_s, hMin, hMax, sMin, vMin, minArea, dilationRadius, closingRadius);
        else
            validationBox_s = scaleValidationBox(validationBox, scaleFactor);
            validationBoxTolerance_s = validationBoxTolerance * scaleFactor;
            [theta_s, ~, ~, ~, ~, ~] = calculateFrameAngleInValidationBox(frameScaled, mRef_s, validationBox_s, ...
                        minArea, smoothWindow, yLower, yUpper, ...
                        hMin, hMax, sMin, vMin, edgeThreshold, dilationRadius, closingRadius, ...
                        validationBoxTolerance_s, cx_s, cy_s, r_s, drumTolerance_s);
            density_s = calculateBoxDensity(frameScaled, validationBox_s, hMin, hMax, sMin, vMin, minArea, dilationRadius, closingRadius);
        end
        
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
