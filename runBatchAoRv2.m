% runBatchAoR_colors.m
clear; clc; close all;

% ---------------- COMMON PARAMETERS ----------------
params = struct();
params.minArea = 500;
params.excludeApexPixels = 20;
params.hueLow1 = 0;     params.hueHigh1 = 0.06;
params.hueLow2 = 0.95;  params.hueHigh2 = 1;
params.satMin = 0.35;
params.valMin = 0.20;
params.sgolayWindow = 21;
params.slideWindowMinPts = 30;
params.slideWindowMaxPts = 80;
params.slideR2Min = 0.97;
params.rotateAngle = -90;
params.showPlots = false;

groups = {'green','red','yellow'};

allResults = struct();
summary = [];
annotatedImages = {};
annotatedLabels = {};

outDir = 'annotated_output';
if ~exist(outDir, 'dir')
    mkdir(outDir);
end

for g = 1:numel(groups)
    groupName = groups{g};
    files = dir(sprintf('%s*.jpg', groupName));

    if isempty(files)
        fprintf('No files found for %s*.jpg\n', groupName);
        continue;
    end

    fprintf('\n=== Processing %s (%d images) ===\n', groupName, numel(files));
    groupResults = [];

    for k = 1:numel(files)
        imgPath = files(k).name;

        try
            % measureAngleOfRepose must return plotting geometry too
            res = measureAngleOfRepose(imgPath, params);

            groupResults = [groupResults; res]; %#ok<AGROW>

            fprintf('  %s: thetaMean = %.2f° (L=%.2f°, R=%.2f°, R2L=%.3f, R2R=%.3f)\n', ...
                imgPath, res.thetaMean, res.thetaLeft, res.thetaRight, ...
                res.R2Left, res.R2Right);

            % Read and rotate image same as analysis
            I = imread(imgPath);
            if params.rotateAngle ~= 0
                I = imrotate(I, params.rotateAngle);
            end

            % Create invisible figure for annotation
            hFig = figure('Visible','off');
            imshow(I); hold on;

            % Plot left and right fitted lines
            % These fields must be returned by measureAngleOfRepose
            plot(res.leftLineX,  res.leftLineY,  'g-', 'LineWidth', 2);
            plot(res.rightLineX, res.rightLineY, 'g-', 'LineWidth', 2);

            % Plot apex if available
            if isfield(res, 'apexX') && isfield(res, 'apexY')
                plot(res.apexX, res.apexY, 'ro', 'MarkerSize', 8, 'LineWidth', 1.5);
            end

            % Add text
            txt = sprintf('%s | AoR = %.2f° | L = %.2f° | R = %.2f°', ...
                imgPath, res.thetaMean, res.thetaLeft, res.thetaRight);

            text(10, 25, txt, ...
                'Color', 'w', ...
                'FontSize', 14, ...
                'FontWeight', 'bold', ...
                'BackgroundColor', 'k', ...
                'Margin', 4, ...
                'Interpreter', 'none');

            % Capture annotated figure as image
            frame = getframe(gca);
            RGB_annot = frame.cdata;

            annotatedImages{end+1} = RGB_annot; %#ok<AGROW>
            annotatedLabels{end+1} = imgPath; %#ok<AGROW>

            % Save annotated image
            [~, name, ~] = fileparts(imgPath);
            outFile = fullfile(outDir, [name '_annotated.jpg']);
            imwrite(RGB_annot, outFile);

            close(hFig);

        catch ME
            fprintf('  %s: ERROR: %s\n', imgPath, ME.message);
        end
    end

    if isempty(groupResults)
        fprintf('No valid results for %s\n', groupName);
        continue;
    end

    allResults.(groupName) = groupResults;

    thetaLeftVals  = [groupResults.thetaLeft];
    thetaRightVals = [groupResults.thetaRight];
    thetaMeanVals  = [groupResults.thetaMean];

    summaryRow = struct();
    summaryRow.Group = groupName;
    summaryRow.N = numel(thetaMeanVals);
    summaryRow.thetaL_mean = mean(thetaLeftVals);
    summaryRow.thetaL_std = std(thetaLeftVals);
    summaryRow.thetaR_mean = mean(thetaRightVals);
    summaryRow.thetaR_std = std(thetaRightVals);
    summaryRow.thetaMean_mean = mean(thetaMeanVals);
    summaryRow.thetaMean_std = std(thetaMeanVals);
    summaryRow.deltaLR_mean = mean([groupResults.deltaThetaLR]);
    summaryRow.R2L_mean = mean([groupResults.R2Left]);
    summaryRow.R2R_mean = mean([groupResults.R2Right]);

    summary = [summary; summaryRow]; %#ok<AGROW>
end

% ---------------- DISPLAY SUMMARY TABLE AND PLOT ----------------
if ~isempty(summary)
    T = struct2table(summary);
    disp(' ');
    disp('Summary of angle of repose per group:');
    disp(T);

    figure('Name','AoR Summary','NumberTitle','off');
    x = 1:height(T);
    errorbar(x, T.thetaMean_mean, T.thetaMean_std, 'ko-', 'LineWidth', 1.5);
    set(gca, 'XTick', x, 'XTickLabel', T.Group, 'XTickLabelRotation', 30);
    ylabel('Angle of repose [deg]');
    grid on;
    title('Mean angle of repose per group (±1 SD)');
end

% ---------------- MONTAGE ----------------
if ~isempty(annotatedImages)
    figure('Name','AoR Montage','NumberTitle','off');
    montage(annotatedImages, 'Size', [], 'BorderSize', [5 5], 'BackgroundColor', 'black');
    title('Angle of Repose - Annotated Images');
end