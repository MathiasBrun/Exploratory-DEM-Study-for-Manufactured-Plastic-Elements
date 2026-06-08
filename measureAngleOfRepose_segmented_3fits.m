function result = measureAngleOfRepose_segmented_3fits(imgPath, params)
% measureAngleOfRepose_segmented_3fits
%
% Measures angle of repose and pile shape using:
%   - HSV colour segmentation
%   - upper boundary extraction
%   - robust apex detection
%   - 3 fitted lines per side for global AoR
%   - fixed-width segmented local boundary profile
%
% Global AoR:
%   left AoR  = average of 3 fitted-line angles on left side
%   right AoR = average of 3 fitted-line angles on right side
%   mean AoR  = average of left and right AoR

    %% ---------------- DEFAULTS & INIT ----------------
    if nargin < 2
        params = struct();
    end

    params = applyDefaults_segmented_3fits(params);
    result = initResult_segmented_3fits(imgPath, params);

    %% ---------------- CHECK FILE ----------------
    if ~isfile(imgPath)
        result.errorMsg = sprintf('File not found: %s', imgPath);
        return;
    end

    %% ---------------- LOAD IMAGE ----------------
    try
        I = imread(imgPath);
    catch ME
        result.errorMsg = sprintf('Unable to read image %s: %s', imgPath, ME.message);
        return;
    end

    if ndims(I) == 2
        I = repmat(I, [1 1 3]);
        appendWarning('Input image was grayscale; converted to RGB.');
    end

    if ndims(I) == 3 && size(I,3) == 4
        I = I(:,:,1:3);
        appendWarning('Input image had alpha channel; ignored alpha channel.');
    end

    if ndims(I) ~= 3 || size(I,3) ~= 3
        result.errorMsg = sprintf('Image %s could not be converted to RGB.', imgPath);
        return;
    end

    %% ---------------- ROTATE IMAGE ----------------
    if params.rotateAngle ~= 0
        I = imrotate(I, params.rotateAngle);
    end

    result.imageSize = size(I);

    %% ---------------- HSV SEGMENTATION ----------------
    Ihsv = rgb2hsv(I);

    H = Ihsv(:,:,1);
    S = Ihsv(:,:,2);
    V = Ihsv(:,:,3);

    mask1 = H >= params.hueLow1 & H <= params.hueHigh1 & ...
            S >= params.satMin  & V >= params.valMin;

    if params.hueLow2 < params.hueHigh2
        mask2 = H >= params.hueLow2 & H <= params.hueHigh2 & ...
                S >= params.satMin  & V >= params.valMin;
    else
        mask2 = false(size(H));
    end

    rawMask = mask1 | mask2;
    result.maskRaw = rawMask;

    if nnz(rawMask) == 0
        result.errorMsg = sprintf('No raw %s pixels detected in %s.', ...
            params.pileColor, imgPath);
        return;
    end

    %% ---------------- CLEAN MASK ----------------
    cleanMask = imfill(rawMask, 'holes');
    cleanMask = bwareaopen(cleanMask, params.minArea);

    if params.openRadius > 0
        cleanMask = imopen(cleanMask, strel('disk', params.openRadius));
    end

    if params.closeRadius > 0
        cleanMask = imclose(cleanMask, strel('disk', params.closeRadius));
    end

    cleanMask = imfill(cleanMask, 'holes');

    %% ---------------- SELECT MAIN PILE OBJECT ----------------
    cc = bwconncomp(cleanMask);

    if cc.NumObjects == 0
        result.errorMsg = sprintf('No cleaned %s region detected in %s.', ...
            params.pileColor, imgPath);
        return;
    end

    stats = regionprops(cc, 'Area', 'BoundingBox');

    scores = zeros(1, numel(stats));

    for k = 1:numel(stats)
        bb = stats(k).BoundingBox;
        yBottom = bb(2) + bb(4);

        scores(k) = stats(k).Area + params.bottomBiasWeight * yBottom;
    end

    [~, idxBest] = max(scores);

    pileMask = false(size(cleanMask));
    pileMask(cc.PixelIdxList{idxBest}) = true;

    pileMask = imclose(pileMask, ...
        strel('disk', max(2, round(params.closeRadius * 1.2))));

    pileMask = imfill(pileMask, 'holes');

    result.maskClean = pileMask;

    %% ---------------- BASIC SHAPE METRICS ----------------
    pileStats = regionprops(pileMask, 'Area', 'BoundingBox');

    if isempty(pileStats)
        result.errorMsg = sprintf('Could not calculate pile shape metrics in %s.', imgPath);
        return;
    end

    bb = pileStats(1).BoundingBox;

    result.pileAreaPx   = pileStats(1).Area;
    result.pileWidthPx  = bb(3);
    result.pileHeightPx = bb(4);

    if result.pileWidthPx > 0
        result.heightWidthRatio = result.pileHeightPx / result.pileWidthPx;
    else
        result.heightWidthRatio = NaN;
    end

    %% ---------------- EXTRACT TOP BOUNDARY ----------------
    [~, nCols] = size(pileMask);

    xVals = [];
    yTop  = [];

    for x = 1:nCols

        y = find(pileMask(:,x), 1, 'first');

        if ~isempty(y)
            xVals(end+1) = x; %#ok<AGROW>
            yTop(end+1)  = y; %#ok<AGROW>
        end
    end

    if numel(xVals) < 2
        result.errorMsg = sprintf('Too few boundary points detected in %s.', imgPath);
        return;
    end

    %% ---------------- TRIM EXTREME EDGES ----------------
    if params.edgeTrimFraction > 0

        xMinAll   = min(xVals);
        xMaxAll   = max(xVals);
        xRangeAll = xMaxAll - xMinAll;

        keep = xVals >= xMinAll + params.edgeTrimFraction*xRangeAll & ...
               xVals <= xMaxAll - params.edgeTrimFraction*xRangeAll;

        if nnz(keep) >= params.minBoundaryPoints
            xVals = xVals(keep);
            yTop  = yTop(keep);
        end
    end

    result.xBoundaryRaw    = xVals;
    result.yBoundaryRaw    = yTop;
    result.nBoundaryPoints = numel(xVals);

    if numel(xVals) < params.minBoundaryPoints
        appendWarning(sprintf('Few boundary points (%d). Measurement may be unreliable.', ...
            numel(xVals)));
    end

    %% ---------------- SMOOTH BOUNDARY ----------------
    sgWin = params.sgolayWindow;

    if mod(sgWin,2) == 0
        sgWin = sgWin + 1;
    end

    sgWin = min(sgWin, numel(yTop));

    if mod(sgWin,2) == 0
        sgWin = sgWin - 1;
    end

    if sgWin >= 5 && numel(yTop) >= sgWin
        ySmooth = smoothdata(yTop, 'sgolay', sgWin);
    else
        ySmooth = yTop;
        appendWarning('Boundary was not smoothed because too few points were available.');
    end

    result.xBoundary = xVals;
    result.yBoundary = ySmooth;

    %% ---------------- ROBUST APEX ----------------
    [xApex, yApex] = robustApex_segmented_3fits(xVals, ySmooth, params);

    result.xApex = xApex;
    result.yApex = yApex;

    %% ---------------- LEFT AND RIGHT CORNERS ----------------
    [xLeftCorner, yLeftCorner, xRightCorner, yRightCorner] = ...
        findBoundaryCorners_segmented_3fits(xVals, ySmooth, xApex, params);

    result.xLeftCorner  = xLeftCorner;
    result.yLeftCorner  = yLeftCorner;
    result.xRightCorner = xRightCorner;
    result.yRightCorner = yRightCorner;

    if any(isnan([xLeftCorner, yLeftCorner, xRightCorner, yRightCorner]))
        result.errorMsg = sprintf('Unable to determine pile corners in %s.', imgPath);
        return;
    end

    %% ---------------- GLOBAL AOR USING 3 FITTED LINES PER SIDE ----------------
    [leftAngles, leftSlopes, leftIntercepts, leftR2, leftXLine, leftYLine] = ...
        fitMultipleSideLines_segmented_3fits( ...
            xVals, ySmooth, ...
            xLeftCorner, xApex, ...
            params.nGlobalSideFits, params.minGlobalFitPoints);

    [rightAngles, rightSlopes, rightIntercepts, rightR2, rightXLine, rightYLine] = ...
        fitMultipleSideLines_segmented_3fits( ...
            xVals, ySmooth, ...
            xApex, xRightCorner, ...
            params.nGlobalSideFits, params.minGlobalFitPoints);

    thetaLeftGlobal  = mean(leftAngles,  'omitnan');
    thetaRightGlobal = mean(rightAngles, 'omitnan');

    if isnan(thetaLeftGlobal) || isnan(thetaRightGlobal)
        result.errorMsg = sprintf('Unable to determine 3-fit global AoR in %s.', imgPath);
        return;
    end

    thetaMeanGlobal = mean([thetaLeftGlobal, thetaRightGlobal], 'omitnan');
    deltaThetaGlobalLR = abs(thetaLeftGlobal - thetaRightGlobal);

    result.thetaLeftGlobal     = thetaLeftGlobal;
    result.thetaRightGlobal    = thetaRightGlobal;
    result.thetaMeanGlobal     = thetaMeanGlobal;
    result.deltaThetaGlobalLR  = deltaThetaGlobalLR;

    result.leftGlobalFitAngles  = leftAngles;
    result.rightGlobalFitAngles = rightAngles;

    result.leftGlobalFitSlopes  = leftSlopes;
    result.rightGlobalFitSlopes = rightSlopes;

    result.leftGlobalFitIntercepts  = leftIntercepts;
    result.rightGlobalFitIntercepts = rightIntercepts;

    result.leftGlobalFitR2  = leftR2;
    result.rightGlobalFitR2 = rightR2;

    result.leftGlobalFitXLine  = leftXLine;
    result.leftGlobalFitYLine  = leftYLine;
    result.rightGlobalFitXLine = rightXLine;
    result.rightGlobalFitYLine = rightYLine;

    result.mLeftGlobal  = mean(leftSlopes,  'omitnan');
    result.bLeftGlobal  = mean(leftIntercepts,  'omitnan');
    result.mRightGlobal = mean(rightSlopes, 'omitnan');
    result.bRightGlobal = mean(rightIntercepts, 'omitnan');

    % Main line fields for compatibility.
    midIdx = ceil(params.nGlobalSideFits / 2);

    result.xLineLeftGlobal  = leftXLine{midIdx};
    result.yLineLeftGlobal  = leftYLine{midIdx};
    result.xLineRightGlobal = rightXLine{midIdx};
    result.yLineRightGlobal = rightYLine{midIdx};

    %% ---------------- LOCAL SEGMENTED BOUNDARY FITS ----------------
    [segAngles, segSlopes, segIntercepts, segR2, segN, segXMid, ...
        segXLine, segYLine, segSide] = localSegmentFits_segmented_3fits( ...
            xVals, ySmooth, xApex, params);

    result.segmentAngles     = segAngles;
    result.segmentSlopes     = segSlopes;
    result.segmentIntercepts = segIntercepts;
    result.segmentR2         = segR2;
    result.segmentNPoints    = segN;
    result.segmentXMid       = segXMid;
    result.segmentXLine      = segXLine;
    result.segmentYLine      = segYLine;
    result.segmentSide       = segSide;

    validSeg = ~isnan(segAngles);

    result.nSegments      = params.nSegments;
    result.nValidSegments = sum(validSeg);

    if result.nValidSegments < round(0.5*params.nSegments)
        appendWarning(sprintf('Only %d/%d local segments were valid.', ...
            result.nValidSegments, params.nSegments));
    end

    result.localAngleMean   = mean(segAngles(validSeg), 'omitnan');
    result.localAngleMedian = median(segAngles(validSeg), 'omitnan');
    result.localAngleStd    = std(segAngles(validSeg), 'omitnan');

    if any(validSeg)
        result.localAngleMax = max(segAngles(validSeg));
        result.localAngleMin = min(segAngles(validSeg));
    else
        result.localAngleMax = NaN;
        result.localAngleMin = NaN;
    end

    leftSeg  = strcmp(segSide, 'left')  & validSeg;
    rightSeg = strcmp(segSide, 'right') & validSeg;

    result.localAngleLeftMean  = mean(segAngles(leftSeg),  'omitnan');
    result.localAngleRightMean = mean(segAngles(rightSeg), 'omitnan');

    %% ---------------- WARNINGS ----------------
    if thetaLeftGlobal < params.minReasonableAoR_deg || ...
       thetaRightGlobal < params.minReasonableAoR_deg

        appendWarning(sprintf('Very low global angle detected (L=%.2f, R=%.2f).', ...
            thetaLeftGlobal, thetaRightGlobal));
    end

    if thetaLeftGlobal > params.maxReasonableAoR_deg || ...
       thetaRightGlobal > params.maxReasonableAoR_deg

        appendWarning(sprintf('Very high global angle detected (L=%.2f, R=%.2f).', ...
            thetaLeftGlobal, thetaRightGlobal));
    end

    if deltaThetaGlobalLR > params.maxDeltaLRWarning_deg
        appendWarning(sprintf('Large global left/right difference detected (Delta=%.2f deg).', ...
            deltaThetaGlobalLR));
    end

    lowR2Segments = segR2 < params.minSegmentR2Warning & ~isnan(segR2);

    if any(lowR2Segments)
        appendWarning(sprintf('%d local segment fits had R^2 below %.2f.', ...
            sum(lowR2Segments), params.minSegmentR2Warning));
    end

    lowR2GlobalLeft  = leftR2  < params.minSegmentR2Warning & ~isnan(leftR2);
    lowR2GlobalRight = rightR2 < params.minSegmentR2Warning & ~isnan(rightR2);

    if any(lowR2GlobalLeft) || any(lowR2GlobalRight)
        appendWarning(sprintf('Some 3-fit global lines had R^2 below %.2f.', ...
            params.minSegmentR2Warning));
    end

    %% ---------------- MARK VALID ----------------
    result.isValid = true;
    result.errorMsg = '';

    %% ---------------- OPTIONAL DEBUG PLOT ----------------
    if params.showPlots

        figure('Name', sprintf('Segmented 3-fit AoR Debug: %s', imgPath), ...
            'NumberTitle', 'off');

        subplot(2,2,1);
        imshow(I);
        title(sprintf('Image: %s', imgPath), 'Interpreter', 'none');

        subplot(2,2,2);
        imshow(result.maskRaw);
        title(sprintf('Raw %s mask', params.pileColor), 'Interpreter', 'none');

        subplot(2,2,3);
        imshow(result.maskClean);
        title('Cleaned pile mask');

        subplot(2,2,4);
        imshow(I); hold on;

        plot(result.xBoundary, result.yBoundary, 'c-', 'LineWidth', 2);

        plot(result.xApex, result.yApex, 'yo', 'MarkerSize', 9, 'LineWidth', 2);
        plot(result.xLeftCorner, result.yLeftCorner, 'go', 'MarkerSize', 8, 'LineWidth', 2);
        plot(result.xRightCorner, result.yRightCorner, 'mo', 'MarkerSize', 8, 'LineWidth', 2);

        for j = 1:numel(result.leftGlobalFitXLine)
            if ~isempty(result.leftGlobalFitXLine{j})
                plot(result.leftGlobalFitXLine{j}, result.leftGlobalFitYLine{j}, ...
                    'g-', 'LineWidth', 3);
            end
        end

        for j = 1:numel(result.rightGlobalFitXLine)
            if ~isempty(result.rightGlobalFitXLine{j})
                plot(result.rightGlobalFitXLine{j}, result.rightGlobalFitYLine{j}, ...
                    'm-', 'LineWidth', 3);
            end
        end

        for s = 1:result.nSegments
            if ~isempty(result.segmentXLine{s})
                plot(result.segmentXLine{s}, result.segmentYLine{s}, ...
                    'w-', 'LineWidth', 1.2);
            end
        end

        title(sprintf('Global AoR %.2f deg | Local mean %.2f deg', ...
            result.thetaMeanGlobal, result.localAngleMean));

        hold off;
    end

    %% ---------------- SAVE DEBUG IMAGE ----------------
    if params.saveDebugImages

        try
            if ~exist(params.debugDir, 'dir')
                mkdir(params.debugDir);
            end

            [~, stem, ~] = fileparts(imgPath);
            debugFile = fullfile(params.debugDir, [stem '_debug.png']);

            hDbg = figure('Visible','off', 'Color','w');

            subplot(2,2,1);
            imshow(I);
            title('Input image');

            subplot(2,2,2);
            imshow(result.maskRaw);
            title('Raw mask');

            subplot(2,2,3);
            imshow(result.maskClean);
            title('Cleaned mask');

            subplot(2,2,4);
            imshow(I); hold on;

            plot(result.xBoundary, result.yBoundary, 'c-', 'LineWidth', 2);

            plot(result.xApex, result.yApex, 'yo', 'MarkerSize', 9, 'LineWidth', 2);
            plot(result.xLeftCorner, result.yLeftCorner, 'go', 'MarkerSize', 8, 'LineWidth', 2);
            plot(result.xRightCorner, result.yRightCorner, 'mo', 'MarkerSize', 8, 'LineWidth', 2);

            for j = 1:numel(result.leftGlobalFitXLine)
                if ~isempty(result.leftGlobalFitXLine{j})
                    plot(result.leftGlobalFitXLine{j}, result.leftGlobalFitYLine{j}, ...
                        'g-', 'LineWidth', 3);
                end
            end

            for j = 1:numel(result.rightGlobalFitXLine)
                if ~isempty(result.rightGlobalFitXLine{j})
                    plot(result.rightGlobalFitXLine{j}, result.rightGlobalFitYLine{j}, ...
                        'm-', 'LineWidth', 3);
                end
            end

            for s = 1:result.nSegments
                if ~isempty(result.segmentXLine{s})
                    plot(result.segmentXLine{s}, result.segmentYLine{s}, ...
                        'w-', 'LineWidth', 1.2);
                end
            end

            title(sprintf('Global %.2f deg | Local mean %.2f deg', ...
                result.thetaMeanGlobal, result.localAngleMean));

            hold off;

            exportgraphics(hDbg, debugFile, 'Resolution', 150);
            close(hDbg);

        catch
            % Do not invalidate measurement if debug saving fails.
        end
    end

    %% ---------------- NESTED WARNING HELPER ----------------
    function appendWarning(msg)
        if strlength(result.warningMsg) == 0
            result.warningMsg = string(msg);
        else
            result.warningMsg = result.warningMsg + " | " + string(msg);
        end
    end
end

% ======================================================================= %
function params = applyDefaults_segmented_3fits(params)

    if ~isfield(params, 'pileColor'), params.pileColor = 'red'; end

    if ~isfield(params, 'rotateAngle'), params.rotateAngle = 0; end

    if ~isfield(params, 'nGlobalSideFits'),    params.nGlobalSideFits = 3; end
    if ~isfield(params, 'minGlobalFitPoints'), params.minGlobalFitPoints = 4; end

    if ~isfield(params, 'nSegments'), params.nSegments = 20; end

    if ~isfield(params, 'showPlots'),       params.showPlots = false; end
    if ~isfield(params, 'saveDebugImages'), params.saveDebugImages = false; end
    if ~isfield(params, 'debugDir'),        params.debugDir = pwd; end

    if ~isfield(params, 'minArea'),          params.minArea = 100; end
    if ~isfield(params, 'openRadius'),       params.openRadius = 2; end
    if ~isfield(params, 'closeRadius'),      params.closeRadius = 8; end
    if ~isfield(params, 'bottomBiasWeight'), params.bottomBiasWeight = 0.001; end

    if ~isfield(params, 'minBoundaryPoints'), params.minBoundaryPoints = 30; end
    if ~isfield(params, 'sgolayWindow'),      params.sgolayWindow = 31; end
    if ~isfield(params, 'edgeTrimFraction'),  params.edgeTrimFraction = 0.01; end

    if ~isfield(params, 'centralApexFraction'), params.centralApexFraction = 0.70; end
    if ~isfield(params, 'highPointFraction'),   params.highPointFraction = 0.07; end

    if ~isfield(params, 'cornerPointCount'),     params.cornerPointCount = 8; end
    if ~isfield(params, 'cornerSearchFraction'), params.cornerSearchFraction = 0.12; end

    if ~isfield(params, 'minSegmentPoints'),    params.minSegmentPoints = 4; end
    if ~isfield(params, 'minSegmentR2Warning'), params.minSegmentR2Warning = 0.70; end

    if ~isfield(params, 'minReasonableAoR_deg'),  params.minReasonableAoR_deg = 1; end
    if ~isfield(params, 'maxReasonableAoR_deg'),  params.maxReasonableAoR_deg = 75; end
    if ~isfield(params, 'maxDeltaLRWarning_deg'), params.maxDeltaLRWarning_deg = 30; end

    hasHue = isfield(params,'hueLow1') && isfield(params,'hueHigh1') && ...
             isfield(params,'hueLow2') && isfield(params,'hueHigh2') && ...
             isfield(params,'satMin')  && isfield(params,'valMin');

    if ~hasHue

        switch lower(params.pileColor)

            case 'red'
                params.hueLow1  = 0.00;
                params.hueHigh1 = 0.07;
                params.hueLow2  = 0.93;
                params.hueHigh2 = 1.00;
                params.satMin   = 0.25;
                params.valMin   = 0.20;

            case 'green'
                params.hueLow1  = 0.20;
                params.hueHigh1 = 0.48;
                params.hueLow2  = 0.00;
                params.hueHigh2 = 0.00;
                params.satMin   = 0.20;
                params.valMin   = 0.18;

            case 'yellow'
                params.hueLow1  = 0.08;
                params.hueHigh1 = 0.25;
                params.hueLow2  = 0.00;
                params.hueHigh2 = 0.00;
                params.satMin   = 0.20;
                params.valMin   = 0.25;

            otherwise
                error('Unsupported pileColor: %s', params.pileColor);
        end
    end
end

% ======================================================================= %
function result = initResult_segmented_3fits(imgPath, params)

    result = struct();

    result.imgPath    = imgPath;
    result.pileColor  = params.pileColor;
    result.isValid    = false;
    result.errorMsg   = '';
    result.warningMsg = "";

    result.imageSize = [];
    result.maskRaw   = [];
    result.maskClean = [];

    result.nBoundaryPoints = 0;
    result.xBoundaryRaw = [];
    result.yBoundaryRaw = [];
    result.xBoundary = [];
    result.yBoundary = [];

    result.xApex = NaN;
    result.yApex = NaN;

    result.xLeftCorner  = NaN;
    result.yLeftCorner  = NaN;
    result.xRightCorner = NaN;
    result.yRightCorner = NaN;

    result.thetaLeftGlobal  = NaN;
    result.thetaRightGlobal = NaN;
    result.thetaMeanGlobal  = NaN;
    result.deltaThetaGlobalLR = NaN;

    result.mLeftGlobal  = NaN;
    result.bLeftGlobal  = NaN;
    result.mRightGlobal = NaN;
    result.bRightGlobal = NaN;

    result.xLineLeftGlobal  = [];
    result.yLineLeftGlobal  = [];
    result.xLineRightGlobal = [];
    result.yLineRightGlobal = [];

    result.leftGlobalFitAngles  = NaN(1, params.nGlobalSideFits);
    result.rightGlobalFitAngles = NaN(1, params.nGlobalSideFits);

    result.leftGlobalFitSlopes  = NaN(1, params.nGlobalSideFits);
    result.rightGlobalFitSlopes = NaN(1, params.nGlobalSideFits);

    result.leftGlobalFitIntercepts  = NaN(1, params.nGlobalSideFits);
    result.rightGlobalFitIntercepts = NaN(1, params.nGlobalSideFits);

    result.leftGlobalFitR2  = NaN(1, params.nGlobalSideFits);
    result.rightGlobalFitR2 = NaN(1, params.nGlobalSideFits);

    result.leftGlobalFitXLine  = cell(1, params.nGlobalSideFits);
    result.leftGlobalFitYLine  = cell(1, params.nGlobalSideFits);
    result.rightGlobalFitXLine = cell(1, params.nGlobalSideFits);
    result.rightGlobalFitYLine = cell(1, params.nGlobalSideFits);

    result.nSegments = params.nSegments;
    result.nValidSegments = 0;

    result.segmentAngles     = NaN(1, params.nSegments);
    result.segmentSlopes     = NaN(1, params.nSegments);
    result.segmentIntercepts = NaN(1, params.nSegments);
    result.segmentR2         = NaN(1, params.nSegments);
    result.segmentNPoints    = zeros(1, params.nSegments);
    result.segmentXMid       = NaN(1, params.nSegments);
    result.segmentSide       = repmat({''}, 1, params.nSegments);
    result.segmentXLine      = cell(1, params.nSegments);
    result.segmentYLine      = cell(1, params.nSegments);

    result.localAngleMean = NaN;
    result.localAngleMedian = NaN;
    result.localAngleStd = NaN;
    result.localAngleMax = NaN;
    result.localAngleMin = NaN;
    result.localAngleLeftMean = NaN;
    result.localAngleRightMean = NaN;

    result.pileWidthPx  = NaN;
    result.pileHeightPx = NaN;
    result.pileAreaPx   = NaN;
    result.heightWidthRatio = NaN;
end

% ======================================================================= %
function [xApex, yApex] = robustApex_segmented_3fits(xVals, yVals, params)
% Robust apex detection.
% In image coordinates, smaller y means higher point.

    xMin = min(xVals);
    xMax = max(xVals);
    xRange = xMax - xMin;

    marginFraction = (1 - params.centralApexFraction) / 2;

    centralLogical = xVals >= xMin + marginFraction*xRange & ...
                     xVals <= xMax - marginFraction*xRange;

    if nnz(centralLogical) >= 5
        xSearch = xVals(centralLogical);
        ySearch = yVals(centralLogical);
    else
        xSearch = xVals;
        ySearch = yVals;
    end

    nHigh = max(3, round(params.highPointFraction * numel(ySearch)));
    nHigh = min(nHigh, numel(ySearch));

    [~, sortIdx] = sort(ySearch, 'ascend');

    highIdx = sortIdx(1:nHigh);

    xApex = median(xSearch(highIdx));
    yApex = median(ySearch(highIdx));
end

% ======================================================================= %
function [xLeftCorner, yLeftCorner, xRightCorner, yRightCorner] = ...
    findBoundaryCorners_segmented_3fits(xVals, yVals, xApex, params)

    n = numel(xVals);

    if n < 2
        xLeftCorner  = NaN;
        yLeftCorner  = NaN;
        xRightCorner = NaN;
        yRightCorner = NaN;
        return;
    end

    xMin = min(xVals);
    xMax = max(xVals);
    xRange = xMax - xMin;

    leftZone  = xVals <= xMin + params.cornerSearchFraction*xRange;
    rightZone = xVals >= xMax - params.cornerSearchFraction*xRange;

    if nnz(leftZone) < 2 || nnz(rightZone) < 2

        nCorner = params.cornerPointCount;
        nCorner = max(2, min(nCorner, floor(n/4)));

        leftIdx  = 1:nCorner;
        rightIdx = (n-nCorner+1):n;

    else

        leftIdx  = find(leftZone);
        rightIdx = find(rightZone);

        nCorner = params.cornerPointCount;

        if numel(leftIdx) > nCorner
            leftIdx = leftIdx(1:nCorner);
        end

        if numel(rightIdx) > nCorner
            rightIdx = rightIdx(end-nCorner+1:end);
        end
    end

    xLeftCorner = median(xVals(leftIdx));
    yLeftCorner = median(yVals(leftIdx));

    xRightCorner = median(xVals(rightIdx));
    yRightCorner = median(yVals(rightIdx));

    if xLeftCorner >= xApex
        validLeft = xVals < xApex;

        if nnz(validLeft) >= 2
            idx = find(validLeft);
            idx = idx(1:min(params.cornerPointCount, numel(idx)));

            xLeftCorner = median(xVals(idx));
            yLeftCorner = median(yVals(idx));
        end
    end

    if xRightCorner <= xApex
        validRight = xVals > xApex;

        if nnz(validRight) >= 2
            idx = find(validRight);
            idx = idx(max(1, numel(idx)-params.cornerPointCount+1):end);

            xRightCorner = median(xVals(idx));
            yRightCorner = median(yVals(idx));
        end
    end
end

% ======================================================================= %
function [angles, slopes, intercepts, R2vals, xLineCell, yLineCell] = ...
    fitMultipleSideLines_segmented_3fits(xVals, yVals, xStart, xEnd, nFits, minPts)
% Fits nFits local straight lines between xStart and xEnd.
% Used for global AoR calculation.

    angles     = NaN(1, nFits);
    slopes     = NaN(1, nFits);
    intercepts = NaN(1, nFits);
    R2vals     = NaN(1, nFits);

    xLineCell = cell(1, nFits);
    yLineCell = cell(1, nFits);

    xLow  = min(xStart, xEnd);
    xHigh = max(xStart, xEnd);

    if xHigh <= xLow
        return;
    end

    inSide = xVals >= xLow & xVals <= xHigh;

    xSide = xVals(inSide);
    ySide = yVals(inSide);

    if numel(xSide) < minPts
        return;
    end

    edges = linspace(xLow, xHigh, nFits + 1);

    for i = 1:nFits

        if i < nFits
            inBin = xSide >= edges(i) & xSide < edges(i+1);
        else
            inBin = xSide >= edges(i) & xSide <= edges(i+1);
        end

        xSeg = xSide(inBin);
        ySeg = ySide(inBin);

        if numel(xSeg) < minPts
            continue;
        end

        if numel(unique(xSeg)) < 2
            continue;
        end

        p = polyfit(xSeg, ySeg, 1);

        m = p(1);
        b = p(2);

        yFit = polyval(p, xSeg);

        SSres = sum((ySeg - yFit).^2);
        SStot = sum((ySeg - mean(ySeg)).^2);

        if SStot == 0
            R2 = NaN;
        else
            R2 = 1 - SSres/SStot;
        end

        angleDeg = atan(abs(m)) * 180/pi;

        angles(i)     = angleDeg;
        slopes(i)     = m;
        intercepts(i) = b;
        R2vals(i)     = R2;

        xLine = linspace(min(xSeg), max(xSeg), 30);
        yLine = m*xLine + b;

        xLineCell{i} = xLine;
        yLineCell{i} = yLine;
    end
end

% ======================================================================= %
function [segAngles, segSlopes, segIntercepts, segR2, segN, segXMid, ...
          segXLine, segYLine, segSide] = localSegmentFits_segmented_3fits( ...
          xVals, yVals, xApex, params)

    nSegments = params.nSegments;

    segAngles     = NaN(1, nSegments);
    segSlopes     = NaN(1, nSegments);
    segIntercepts = NaN(1, nSegments);
    segR2         = NaN(1, nSegments);
    segN          = zeros(1, nSegments);
    segXMid       = NaN(1, nSegments);
    segXLine      = cell(1, nSegments);
    segYLine      = cell(1, nSegments);
    segSide       = repmat({''}, 1, nSegments);

    xMin = min(xVals);
    xMax = max(xVals);

    edges = linspace(xMin, xMax, nSegments + 1);

    for s = 1:nSegments

        if s < nSegments
            inSeg = xVals >= edges(s) & xVals < edges(s+1);
        else
            inSeg = xVals >= edges(s) & xVals <= edges(s+1);
        end

        xSeg = xVals(inSeg);
        ySeg = yVals(inSeg);

        segN(s) = numel(xSeg);

        if isempty(xSeg)
            continue;
        end

        segXMid(s) = mean(xSeg, 'omitnan');

        if segXMid(s) < xApex
            segSide{s} = 'left';
        elseif segXMid(s) > xApex
            segSide{s} = 'right';
        else
            segSide{s} = 'apex';
        end

        if numel(xSeg) < params.minSegmentPoints
            continue;
        end

        if numel(unique(xSeg)) < 2
            continue;
        end

        p = polyfit(xSeg, ySeg, 1);

        m = p(1);
        b = p(2);

        yFit = polyval(p, xSeg);

        SSres = sum((ySeg - yFit).^2);
        SStot = sum((ySeg - mean(ySeg)).^2);

        if SStot == 0
            R2 = NaN;
        else
            R2 = 1 - SSres/SStot;
        end

        angleDeg = atan(abs(m)) * 180/pi;

        segAngles(s)     = angleDeg;
        segSlopes(s)     = m;
        segIntercepts(s) = b;
        segR2(s)         = R2;

        xLine = linspace(min(xSeg), max(xSeg), 20);
        yLine = m*xLine + b;

        segXLine{s} = xLine;
        segYLine{s} = yLine;
    end
end