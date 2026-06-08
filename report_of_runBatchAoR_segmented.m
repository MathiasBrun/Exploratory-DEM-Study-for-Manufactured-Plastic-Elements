% runBatchAoR_segmented_3fits_byExperiment.m
%
% Batch-process Angle of Repose using:
%   - 3 fitted lines on the left pile side
%   - 3 fitted lines on the right pile side
%   - segmented boundary profile for shape comparison
%
% IMPORTANT LOGIC:
%   Each Up or Down folder is treated as ONE separate experiment.
%   Only the 3 images inside that exact folder are grouped together.
%
% Example:
%   .../2x1/b_mu_d/Down/green1.jpg
%   .../2x1/b_mu_d/Down/green2.jpg
%   .../2x1/b_mu_d/Down/green3.jpg
%   -> these 3 are ONE experiment
%
%   .../2x1/b_mu_d/Up/green1.jpg
%   .../2x1/b_mu_d/Up/green2.jpg
%   .../2x1/b_mu_d/Up/green3.jpg
%   -> these 3 are ANOTHER experiment
%
% The script does NOT pool all green files together across the whole dataset.

clear; clc; close all;

%% ---------------- SETUP ----------------
scriptDir = fileparts(mfilename('fullpath'));
if isempty(scriptDir)
    scriptDir = pwd;
end
cd(scriptDir);
addpath(scriptDir);

if exist('measureAngleOfRepose_segmented_3fits','file') ~= 2
    error('measureAngleOfRepose_segmented_3fits.m not found in %s.', scriptDir);
end

% -------------------------------------------------------------------------
% DATA ROOT
% Change this if needed. This should be the folder containing 2x1 and 2x8.
% -------------------------------------------------------------------------
dataRoot = '/Users/tobiasjones/Library/CloudStorage/OneDrive-Aarhusuniversitet/Anders Ravnsholt Riis''s files - Thesis/08. Callibration/matlab scripts/Calib_ANSYS_AOR';

if ~exist(dataRoot, 'dir')
    error('Data root folder not found:\n%s', dataRoot);
end

topFolders = {'2x1','2x8', 'Flower'};
validColors = {'green','red','yellow'};

outDir        = fullfile(scriptDir, 'AoR_output_segmented_3fits');
annotDir      = fullfile(outDir, 'annotated_images');
debugDir      = fullfile(outDir, 'debug_images');
montageDir    = fullfile(outDir, 'experiment_montages');

if ~exist(outDir, 'dir'),     mkdir(outDir);     end
if ~exist(annotDir, 'dir'),   mkdir(annotDir);   end
if ~exist(debugDir, 'dir'),   mkdir(debugDir);   end
if ~exist(montageDir, 'dir'), mkdir(montageDir); end

%% ---------------- PARAMETERS ----------------
paramsBase = struct();

% Image orientation
paramsBase.rotateAngle = 0;

% Number of fitted lines per side for global AoR
paramsBase.nGlobalSideFits    = 3;
paramsBase.minGlobalFitPoints = 4;

% Number of equal-width boundary segments used for shape profile
paramsBase.nSegments = 20;

% Debugging
paramsBase.showPlots       = false;
paramsBase.saveDebugImages = true;
paramsBase.debugDir        = debugDir;

% Mask cleanup
paramsBase.minArea          = 100;
paramsBase.openRadius       = 2;
paramsBase.closeRadius      = 8;
paramsBase.bottomBiasWeight = 0.001;

% Boundary extraction
paramsBase.minBoundaryPoints = 30;
paramsBase.sgolayWindow      = 31;
paramsBase.edgeTrimFraction  = 0.01;

% Apex detection
paramsBase.centralApexFraction = 0.70;
paramsBase.highPointFraction   = 0.07;

% Corner detection
paramsBase.cornerPointCount     = 8;
paramsBase.cornerSearchFraction = 0.12;

% Local segment fitting
paramsBase.minSegmentPoints    = 4;
paramsBase.minSegmentR2Warning = 0.70;

% Warnings
paramsBase.minReasonableAoR_deg  = 1;
paramsBase.maxReasonableAoR_deg  = 75;
paramsBase.maxDeltaLRWarning_deg = 30;

% Annotated image settings
paramsBase.annotatedImageSize = [650 1450];
paramsBase.captionHeight      = 150;
paramsBase.annotatedPadValue  = 255;
paramsBase.annotationMarginFraction = 0.03;

% Compact montage settings
paramsBase.montageColumns  = 3;
paramsBase.montageBorderPx = 8;
paramsBase.montageBgValue  = 255;
paramsBase.saveStandardMontage = true;

%% ---------------- STORAGE ----------------
allRows        = struct([]);   % one row per image
segmentRows    = struct([]);   % one row per segment per image
experimentRows = struct([]);   % one row per Up/Down folder experiment

%% ---------------- FIND ALL EXPERIMENT FOLDERS ----------------
experimentFolders = struct([]);
expCounter = 0;

for tf = 1:numel(topFolders)
    topFolderName = topFolders{tf};
    topPath = fullfile(dataRoot, topFolderName);

    if ~exist(topPath, 'dir')
        fprintf('Top-level folder not found: %s\n', topPath);
        continue;
    end

    upFolders   = dir(fullfile(topPath, '**', 'Up'));
    downFolders = dir(fullfile(topPath, '**', 'Down'));
    targetFolders = [upFolders; downFolders];
    targetFolders = targetFolders([targetFolders.isdir]);

    for f = 1:numel(targetFolders)
        folderPath = fullfile(targetFolders(f).folder, targetFolders(f).name);

        [parent1, directionName] = fileparts(folderPath);
        [parent2, testFolderName] = fileparts(parent1);
        [~, topFolderParsed] = fileparts(parent2);

        % Detect which color exists in this folder
        foundColors = {};
        for c = 1:numel(validColors)
            colorName = validColors{c};
            jpgs = dir(fullfile(folderPath, [colorName '*.jpg']));
            JPGs = dir(fullfile(folderPath, [colorName '*.JPG']));
            jpegs = dir(fullfile(folderPath, [colorName '*.jpeg']));
            JPEGs = dir(fullfile(folderPath, [colorName '*.JPEG']));
            pngs = dir(fullfile(folderPath, [colorName '*.png']));
            PNGs = dir(fullfile(folderPath, [colorName '*.PNG']));

            colorFiles = [jpgs; JPGs; jpegs; JPEGs; pngs; PNGs];
            if ~isempty(colorFiles)
                foundColors{end+1} = colorName; %#ok<AGROW>
            end
        end

        if isempty(foundColors)
            fprintf('No green/red/yellow images found in: %s\n', folderPath);
            continue;
        end

        if numel(foundColors) > 1
            warning('More than one color set found in folder:\n%s\nUsing first detected color: %s', ...
                folderPath, foundColors{1});
        end

        chosenColor = foundColors{1};

        expCounter = expCounter + 1;
        experimentFolders(expCounter).FolderPath  = folderPath; %#ok<SAGROW>
        experimentFolders(expCounter).TopFolder   = topFolderParsed;
        experimentFolders(expCounter).TestFolder  = testFolderName;
        experimentFolders(expCounter).Direction   = directionName;
        experimentFolders(expCounter).Color       = chosenColor;
    end
end

if isempty(experimentFolders)
    error('No experiment folders were found.');
end

fprintf('\nFound %d experiment folders.\n', numel(experimentFolders));

%% ---------------- MAIN EXPERIMENT LOOP ----------------
for e = 1:numel(experimentFolders)
    expInfo = experimentFolders(e);

    folderPath = expInfo.FolderPath;
    topFolder  = expInfo.TopFolder;
    testFolder = expInfo.TestFolder;
    direction  = expInfo.Direction;
    groupName  = expInfo.Color;

    params = paramsBase;
    params.pileColor = groupName;

    experimentID = sprintf('%s__%s__%s__%s', topFolder, testFolder, direction, groupName);

    fprintf('\n=== Experiment %d / %d ===\n', e, numel(experimentFolders));
    fprintf('ExperimentID: %s\n', experimentID);
    fprintf('Folder: %s\n', folderPath);

    % Find only this folder's images for the detected color
    files = [
        dir(fullfile(folderPath, [groupName '*.jpg']));
        dir(fullfile(folderPath, [groupName '*.JPG']));
        dir(fullfile(folderPath, [groupName '*.jpeg']));
        dir(fullfile(folderPath, [groupName '*.JPEG']));
        dir(fullfile(folderPath, [groupName '*.png']));
        dir(fullfile(folderPath, [groupName '*.PNG']))
    ];

    if isempty(files)
        fprintf('No matching files found in experiment folder.\n');
        continue;
    end

    % Remove duplicates
    fullPaths = fullfile({files.folder}, {files.name});
    fullPathsNorm = lower(fullPaths);
    [~, uniqueIdx] = unique(fullPathsNorm, 'stable');
    files = files(uniqueIdx);

    % Sort by filename so green1, green2, green3 stay ordered
    [~, sortIdx] = sort(lower({files.name}));
    files = files(sortIdx);

    fprintf('Images in this experiment: %d\n', numel(files));

    expImageRows = struct([]);
    expAnnotImgs = {};

    for k = 1:numel(files)
        fname   = files(k).name;
        imgPath = fullfile(files(k).folder, fname);

        fprintf('  Processing %s...\n', fname);

        res = measureAngleOfRepose_segmented_3fits(imgPath, params);

        %% ---------- PER-IMAGE ROW ----------
        row = struct();
        row.ExperimentID = string(experimentID);
        row.File         = string(fname);
        row.Group        = string(groupName);
        row.Directory    = string(files(k).folder);
        row.FullPath     = string(imgPath);
        row.TopFolder    = string(topFolder);
        row.TestFolder   = string(testFolder);
        row.Direction    = string(direction);

        row.IsValid = res.isValid;
        row.GlobalAoR_Left_deg      = res.thetaLeftGlobal;
        row.GlobalAoR_Right_deg     = res.thetaRightGlobal;
        row.GlobalAoR_Mean_deg      = res.thetaMeanGlobal;
        row.GlobalAoR_DeltaLR_deg   = res.deltaThetaGlobalLR;

        for j = 1:params.nGlobalSideFits
            row.(sprintf('LeftGlobalFitAngle_%d_deg', j))  = res.leftGlobalFitAngles(j);
            row.(sprintf('RightGlobalFitAngle_%d_deg', j)) = res.rightGlobalFitAngles(j);
            row.(sprintf('LeftGlobalFitR2_%d', j))         = res.leftGlobalFitR2(j);
            row.(sprintf('RightGlobalFitR2_%d', j))        = res.rightGlobalFitR2(j);
        end

        row.LocalAoR_Mean_deg       = res.localAngleMean;
        row.LocalAoR_Median_deg     = res.localAngleMedian;
        row.LocalAoR_Std_deg        = res.localAngleStd;
        row.LocalAoR_Max_deg        = res.localAngleMax;
        row.LocalAoR_Min_deg        = res.localAngleMin;
        row.LocalAoR_LeftMean_deg   = res.localAngleLeftMean;
        row.LocalAoR_RightMean_deg  = res.localAngleRightMean;
        row.ValidSegments           = res.nValidSegments;
        row.TotalSegments           = res.nSegments;

        row.PileWidth_px      = res.pileWidthPx;
        row.PileHeight_px     = res.pileHeightPx;
        row.PileArea_px       = res.pileAreaPx;
        row.HeightWidthRatio  = res.heightWidthRatio;
        row.BoundaryPoints    = res.nBoundaryPoints;

        row.ApexX = res.xApex;
        row.ApexY = res.yApex;
        row.LeftCornerX  = res.xLeftCorner;
        row.LeftCornerY  = res.yLeftCorner;
        row.RightCornerX = res.xRightCorner;
        row.RightCornerY = res.yRightCorner;

        row.Warning = string(res.warningMsg);
        row.Error   = string(res.errorMsg);

        for s = 1:params.nSegments
            fieldName = sprintf('SegAngle_%02d_deg', s);
            if s <= numel(res.segmentAngles)
                row.(fieldName) = res.segmentAngles(s);
            else
                row.(fieldName) = NaN;
            end
        end

        if isempty(allRows)
            allRows = row;
        else
            allRows(end+1,1) = row; %#ok<AGROW>
        end

        if isempty(expImageRows)
            expImageRows = row;
        else
            expImageRows(end+1,1) = row; %#ok<AGROW>
        end

        %% ---------- LONG-FORM SEGMENT ROWS ----------
        for s = 1:params.nSegments
            srow = struct();
            srow.ExperimentID = string(experimentID);
            srow.File         = string(fname);
            srow.Group        = string(groupName);
            srow.Directory    = string(files(k).folder);
            srow.FullPath     = string(imgPath);
            srow.TopFolder    = string(topFolder);
            srow.TestFolder   = string(testFolder);
            srow.Direction    = string(direction);

            srow.IsValidImage = res.isValid;
            srow.SegmentIndex = s;

            if s <= numel(res.segmentAngles)
                srow.SegmentAngle_deg = res.segmentAngles(s);
                srow.SegmentSlope     = res.segmentSlopes(s);
                srow.SegmentR2        = res.segmentR2(s);
                srow.SegmentNPoints   = res.segmentNPoints(s);
                srow.SegmentXMid      = res.segmentXMid(s);
                srow.SegmentSide      = string(res.segmentSide{s});
            else
                srow.SegmentAngle_deg = NaN;
                srow.SegmentSlope     = NaN;
                srow.SegmentR2        = NaN;
                srow.SegmentNPoints   = 0;
                srow.SegmentXMid      = NaN;
                srow.SegmentSide      = "";
            end

            if isempty(segmentRows)
                segmentRows = srow;
            else
                segmentRows(end+1,1) = srow; %#ok<AGROW>
            end
        end

        if ~res.isValid
            fprintf('    ERROR: %s\n', res.errorMsg);
            continue;
        end

        if strlength(res.warningMsg) > 0
            fprintf('    WARNING: %s\n', res.warningMsg);
        end

        fprintf('    Global AoR = %.2f deg | Left = %.2f | Right = %.2f | Local mean = %.2f | Valid segments = %d/%d\n', ...
            res.thetaMeanGlobal, ...
            res.thetaLeftGlobal, ...
            res.thetaRightGlobal, ...
            res.localAngleMean, ...
            res.nValidSegments, ...
            res.nSegments);

        %% ---------- ANNOTATED IMAGE ----------
        try
            I = imread(imgPath);

            if ndims(I) == 2
                I = repmat(I, [1 1 3]);
            end
            if ndims(I) == 3 && size(I,3) == 4
                I = I(:,:,1:3);
            end
            if params.rotateAngle ~= 0
                I = imrotate(I, params.rotateAngle);
            end

            [imgH, imgW, ~] = size(I);
            marginFrac = params.annotationMarginFraction;
            xMargin = marginFrac * imgW;
            yMargin = marginFrac * imgH;

            hFig = figure( ...
                'Visible','off', ...
                'Color','white', ...
                'Units','pixels', ...
                'Position',[100 100 1600 750]);

            ax = axes('Parent', hFig, ...
                'Units','normalized', ...
                'Position',[0.002 0.002 0.996 0.996]);

            imshow(I, 'Parent', ax);
            hold(ax, 'on');

            xlim(ax, [1 - xMargin, imgW + xMargin]);
            ylim(ax, [1 - yMargin, imgH + yMargin]);
            axis(ax, 'image');
            axis(ax, 'off');

            plot(ax, res.xBoundary, res.yBoundary, 'c-', 'LineWidth', 2);
            plot(ax, res.xApex, res.yApex, 'yo', 'MarkerSize', 9, 'LineWidth', 2);
            plot(ax, res.xLeftCorner, res.yLeftCorner, 'go', 'MarkerSize', 8, 'LineWidth', 2);
            plot(ax, res.xRightCorner, res.yRightCorner, 'mo', 'MarkerSize', 8, 'LineWidth', 2);

            for j = 1:numel(res.leftGlobalFitXLine)
                if ~isempty(res.leftGlobalFitXLine{j})
                    plot(ax, res.leftGlobalFitXLine{j}, res.leftGlobalFitYLine{j}, 'g-', 'LineWidth', 3);
                end
            end

            for j = 1:numel(res.rightGlobalFitXLine)
                if ~isempty(res.rightGlobalFitXLine{j})
                    plot(ax, res.rightGlobalFitXLine{j}, res.rightGlobalFitYLine{j}, 'm-', 'LineWidth', 3);
                end
            end

            for s = 1:res.nSegments
                if ~isempty(res.segmentXLine{s})
                    plot(ax, res.segmentXLine{s}, res.segmentYLine{s}, 'w-', 'LineWidth', 1.2);
                end
            end

            frame = getframe(hFig);
            RGB_annot = frame.cdata;
            close(hFig);

            if params.rotateAngle ~= 0
                RGB_annot = imrotate(RGB_annot, -params.rotateAngle);
            end

            [~, stem, ~] = fileparts(fname);
            captionText = sprintf('%s | %s | %s | %s | Mean AoR = %.1f deg', ...
                topFolder, testFolder, direction, stem, res.thetaMeanGlobal);

            RGB_annot = standardiseAnnotatedImageWithCaption( ...
                RGB_annot, ...
                params.annotatedImageSize, ...
                params.captionHeight, ...
                params.annotatedPadValue, ...
                captionText);

            safeID = matlab.lang.makeValidName(experimentID);
            outFile = fullfile(annotDir, sprintf('%s__%s_annotated.png', safeID, stem));
            imwrite(RGB_annot, outFile);

            expAnnotImgs{end+1} = RGB_annot; %#ok<AGROW>

        catch ME
            fprintf('    Could not save annotation for %s: %s\n', fname, ME.message);
        end
    end

    %% ---------- EXPERIMENT SUMMARY ----------
    if ~isempty(expImageRows)
        Texp = struct2table(expImageRows);
        valid = Texp.IsValid == true & ~isnan(Texp.GlobalAoR_Mean_deg);

        erow = struct();
        erow.ExperimentID = string(experimentID);
        erow.TopFolder    = string(topFolder);
        erow.TestFolder   = string(testFolder);
        erow.Direction    = string(direction);
        erow.Group        = string(groupName);
        erow.FolderPath   = string(folderPath);

        erow.N_total  = height(Texp);
        erow.N_valid  = sum(valid);
        erow.N_failed = height(Texp) - sum(valid);

        erow.GlobalAoR_mean_deg = mean(Texp.GlobalAoR_Mean_deg(valid), 'omitnan');
        erow.GlobalAoR_std_deg  = std(Texp.GlobalAoR_Mean_deg(valid), 'omitnan');
        erow.GlobalAoR_var_deg2 = var(Texp.GlobalAoR_Mean_deg(valid), 'omitnan');

        erow.LeftAoR_mean_deg   = mean(Texp.GlobalAoR_Left_deg(valid), 'omitnan');
        erow.LeftAoR_var_deg2   = var(Texp.GlobalAoR_Left_deg(valid), 'omitnan');

        erow.RightAoR_mean_deg  = mean(Texp.GlobalAoR_Right_deg(valid), 'omitnan');
        erow.RightAoR_var_deg2  = var(Texp.GlobalAoR_Right_deg(valid), 'omitnan');

        erow.LocalAoR_mean_deg  = mean(Texp.LocalAoR_Mean_deg(valid), 'omitnan');
        erow.LocalAoR_std_deg   = std(Texp.LocalAoR_Mean_deg(valid), 'omitnan');
        erow.LocalAoR_var_deg2  = var(Texp.LocalAoR_Mean_deg(valid), 'omitnan');

        erow.LocalShapeStd_mean_deg = mean(Texp.LocalAoR_Std_deg(valid), 'omitnan');
        erow.LocalShapeStd_var_deg2 = var(Texp.LocalAoR_Std_deg(valid), 'omitnan');

        erow.PileWidth_mean_px   = mean(Texp.PileWidth_px(valid), 'omitnan');
        erow.PileWidth_var_px2   = var(Texp.PileWidth_px(valid), 'omitnan');

        erow.PileHeight_mean_px  = mean(Texp.PileHeight_px(valid), 'omitnan');
        erow.PileHeight_var_px2  = var(Texp.PileHeight_px(valid), 'omitnan');

        erow.PileArea_mean_px    = mean(Texp.PileArea_px(valid), 'omitnan');
        erow.PileArea_var_px2    = var(Texp.PileArea_px(valid), 'omitnan');

        erow.HeightWidthRatio_mean = mean(Texp.HeightWidthRatio(valid), 'omitnan');
        erow.HeightWidthRatio_var  = var(Texp.HeightWidthRatio(valid), 'omitnan');

        if isempty(experimentRows)
            experimentRows = erow;
        else
            experimentRows(end+1,1) = erow; %#ok<AGROW>
        end
    end

    %% ---------- PER-EXPERIMENT MONTAGE ----------
    if ~isempty(expAnnotImgs)
        nImgs = numel(expAnnotImgs);
        nCols = min(paramsBase.montageColumns, nImgs);
        nRows = ceil(nImgs / nCols);

        montageImg = makeCompactMontage( ...
            expAnnotImgs, ...
            nRows, ...
            nCols, ...
            paramsBase.montageBorderPx, ...
            paramsBase.montageBgValue);

        safeID = matlab.lang.makeValidName(experimentID);
        montageFile = fullfile(montageDir, sprintf('%s_montage.png', safeID));
        imwrite(montageImg, montageFile);
    end
end

%% ---------------- EXPORT TABLES ----------------
if ~isempty(allRows)
    Tall = struct2table(allRows);

    key = lower(strcat(string(Tall.ExperimentID), "_", string(Tall.FullPath)));
    [~, uniqueRowIdx] = unique(key, 'stable');
    Tall = Tall(uniqueRowIdx, :);

    writetable(Tall, fullfile(outDir, 'AoR_per_image_results.csv'));

    disp(' ');
    disp('Per-image results:');
    disp(Tall);
else
    fprintf('\nNo per-image results were produced.\n');
end

if ~isempty(segmentRows)
    Tseg = struct2table(segmentRows);

    keySeg = lower(strcat( ...
        string(Tseg.ExperimentID), "_", ...
        string(Tseg.FullPath), "_", ...
        string(Tseg.SegmentIndex)));

    [~, uniqueSegIdx] = unique(keySeg, 'stable');
    Tseg = Tseg(uniqueSegIdx, :);

    writetable(Tseg, fullfile(outDir, 'AoR_segment_angles.csv'));
else
    fprintf('\nNo segment-level results were produced.\n');
end

if ~isempty(experimentRows)
    TexpSummary = struct2table(experimentRows);
    writetable(TexpSummary, fullfile(outDir, 'AoR_summary_by_experiment.csv'));

    disp(' ');
    disp('Summary by experiment:');
    disp(TexpSummary);
else
    fprintf('\nNo experiment-level summary results were produced.\n');
end

%% ---------------- OPTIONAL GROUP SUMMARY ----------------
if exist('TexpSummary', 'var') && ~isempty(TexpSummary)
    colors = unique(string(TexpSummary.Group), 'stable');
    groupSummaryRows = struct([]);

    for g = 1:numel(colors)
        thisColor = colors(g);
        idx = strcmp(string(TexpSummary.Group), thisColor);
        Tg = TexpSummary(idx,:);

        grow = struct();
        grow.Group = thisColor;
        grow.N_experiments = height(Tg);
        grow.GlobalAoR_mean_of_experiments_deg = mean(Tg.GlobalAoR_mean_deg, 'omitnan');
        grow.GlobalAoR_std_of_experiments_deg  = std(Tg.GlobalAoR_mean_deg, 'omitnan');
        grow.GlobalAoR_var_of_experiments_deg2 = var(Tg.GlobalAoR_mean_deg, 'omitnan');

        if isempty(groupSummaryRows)
            groupSummaryRows = grow;
        else
            groupSummaryRows(end+1,1) = grow; %#ok<AGROW>
        end
    end

    TgroupSummary = struct2table(groupSummaryRows);
    writetable(TgroupSummary, fullfile(outDir, 'AoR_summary_by_colour.csv'));
end

%% ---------------- SUMMARY PLOT BY EXPERIMENT ----------------
if exist('TexpSummary', 'var') && ~isempty(TexpSummary)
    figure('Name','AoR Summary by Experiment','NumberTitle','off');

    x = 1:height(TexpSummary);
    errorbar(x, ...
        TexpSummary.GlobalAoR_mean_deg, ...
        TexpSummary.GlobalAoR_std_deg, ...
        'ko', ...
        'LineWidth',1.5, ...
        'MarkerFaceColor','w');
    hold on;

    for i = 1:height(TexpSummary)
        text(x(i), TexpSummary.GlobalAoR_mean_deg(i), ...
            sprintf('  %s | %s | %s', ...
            TexpSummary.TopFolder(i), ...
            TexpSummary.TestFolder(i), ...
            TexpSummary.Direction(i)), ...
            'Rotation', 45, 'FontSize', 8);
    end
    hold off;

    xlabel('Experiment index');
    ylabel('Global angle of repose [deg]');
    title('Global angle of repose by experiment, mean \pm 1 SD');
    grid on;

    saveas(gcf, fullfile(outDir, 'AoR_summary_by_experiment.png'));
end

%% ---------------- PER-IMAGE PLOT WITH EXPERIMENT LABELS ----------------
if exist('Tall', 'var') && ~isempty(Tall)
    validRows = Tall.IsValid == true & ~isnan(Tall.GlobalAoR_Mean_deg);

    if any(validRows)
        Tvalid = Tall(validRows, :);
        labels = strcat(Tvalid.TopFolder, " | ", Tvalid.TestFolder, " | ", ...
                        Tvalid.Direction, " | ", Tvalid.File);

        figure('Name','AoR per Image','NumberTitle','off');
        x = 1:height(Tvalid);

        plot(x, Tvalid.GlobalAoR_Left_deg, 'g-o', ...
            'LineWidth', 1.2, 'MarkerFaceColor', 'w');
        hold on;
        plot(x, Tvalid.GlobalAoR_Right_deg, 'm-o', ...
            'LineWidth', 1.2, 'MarkerFaceColor', 'w');
        plot(x, Tvalid.GlobalAoR_Mean_deg, 'k-o', ...
            'LineWidth', 1.8, 'MarkerFaceColor', 'w');
        hold off;

        set(gca, ...
            'XTick', x, ...
            'XTickLabel', cellstr(labels), ...
            'XTickLabelRotation', 45);

        xlabel('Experiment image');
        ylabel('Angle of repose [deg]');
        title('Left, right, and mean AoR for each image');
        legend({'Left AoR', 'Right AoR', 'Mean AoR'}, 'Location','best');
        grid on;

        saveas(gcf, fullfile(outDir, 'AoR_per_image_left_right_mean.png'));
    else
        fprintf('\nNo valid rows available for per-image plots.\n');
    end
end

fprintf('\nDone. Output saved to:\n%s\n', outDir);

%% ======================================================================= %
function Iout = standardiseAnnotatedImageWithCaption(Iin, imageSize, captionHeight, padValue, captionText)
    imageH = imageSize(1);
    imageW = imageSize(2);

    if ndims(Iin) == 2
        Iin = repmat(Iin, [1 1 3]);
    end
    if size(Iin,3) == 4
        Iin = Iin(:,:,1:3);
    end

    Iin = im2uint8(Iin);
    [h, w, ~] = size(Iin);

    scale = min(imageW / w, imageH / h);
    newW = max(1, round(w * scale));
    newH = max(1, round(h * scale));

    Iresized = imresize(Iin, [newH newW]);

    imageCanvas = uint8(padValue * ones(imageH, imageW, 3));
    rowStart = floor((imageH - newH) / 2) + 1;
    colStart = floor((imageW - newW) / 2) + 1;
    rowEnd = rowStart + newH - 1;
    colEnd = colStart + newW - 1;

    imageCanvas(rowStart:rowEnd, colStart:colEnd, :) = Iresized;

    captionCanvas = uint8(padValue * ones(captionHeight, imageW, 3));
    Iout = [imageCanvas; captionCanvas];

    textPos = [22, imageH + 28];
    Iout = insertText(Iout, textPos, captionText, ...
        'FontSize', 86, ...
        'Font', 'Arial Bold', ...
        'BoxColor', 'white', ...
        'BoxOpacity', 0, ...
        'TextColor', 'black');
end

%% ======================================================================= %
function montageImg = makeCompactMontage(imgCell, nRows, nCols, borderPx, bgValue)
    nImgs = numel(imgCell);
    firstImg = imgCell{1};

    if ndims(firstImg) == 2
        firstImg = repmat(firstImg, [1 1 3]);
    end
    firstImg = im2uint8(firstImg);

    [tileH, tileW, ~] = size(firstImg);

    montageH = nRows * tileH + (nRows + 1) * borderPx;
    montageW = nCols * tileW + (nCols + 1) * borderPx;

    montageImg = uint8(bgValue * ones(montageH, montageW, 3));

    for i = 1:nImgs
        row = ceil(i / nCols);
        col = i - (row - 1) * nCols;

        r1 = borderPx + (row - 1) * (tileH + borderPx) + 1;
        r2 = r1 + tileH - 1;
        c1 = borderPx + (col - 1) * (tileW + borderPx) + 1;
        c2 = c1 + tileW - 1;

        thisImg = imgCell{i};
        if ndims(thisImg) == 2
            thisImg = repmat(thisImg, [1 1 3]);
        end
        thisImg = im2uint8(thisImg);

        montageImg(r1:r2, c1:c2, :) = thisImg;
    end
end