function result = measureAngleOfRepose(imgPath, params)
% measureAngleOfRepose  Measure angle of repose from a side-view LEGO pile image.
%
% Usage:
%   result = measureAngleOfRepose('experiment1.jpg', params);
%
% result is a struct with fields:
%   imgPath
%   thetaLeft, thetaRight, thetaMean
%   mLeft, mRight
%   R2Left, R2Right
%   deltaThetaLR         (|thetaLeft - thetaRight|)
%   nBoundaryPoints
%   xBoundary, yBoundary
%   xLeftFit, yLeftFit, xRightFit, yRightFit

    % ---------------- BASIC INPUT CHECKING ----------------
    if nargin < 2
        error('measureAngleOfRepose requires imgPath and params struct.');
    end

    % Set defaults if fields are missing in params
    if ~isfield(params, 'minArea'),            params.minArea = 500;           end
    if ~isfield(params, 'excludeApexPixels'),  params.excludeApexPixels = 20;  end
    if ~isfield(params, 'hueLow1'),            params.hueLow1 = 0;             end
    if ~isfield(params, 'hueHigh1'),           params.hueHigh1 = 0.06;         end
    if ~isfield(params, 'hueLow2'),            params.hueLow2 = 0.95;          end
    if ~isfield(params, 'hueHigh2'),           params.hueHigh2 = 1;            end
    if ~isfield(params, 'satMin'),             params.satMin = 0.35;           end
    if ~isfield(params, 'valMin'),             params.valMin = 0.20;           end
    if ~isfield(params, 'sgolayWindow'),       params.sgolayWindow = 21;       end
    if ~isfield(params, 'slideWindowMinPts'),  params.slideWindowMinPts = 30;  end
    if ~isfield(params, 'slideWindowMaxPts'),  params.slideWindowMaxPts = 80;  end
    if ~isfield(params, 'slideR2Min'),         params.slideR2Min = 0.97;       end
    if ~isfield(params, 'rotateAngle'),        params.rotateAngle = -90;       end
    if ~isfield(params, 'showPlots'),          params.showPlots = false;       end

    % ---------------- LOAD IMAGE ----------------
    if ~isfile(imgPath)
        error('File not found: %s', imgPath);
    end

    I = imread(imgPath);
    if params.rotateAngle ~= 0
        I = imrotate(I, params.rotateAngle);
    end

    % ---------------- SEGMENT RED PILE (HSV) ----------------
    Ihsv = rgb2hsv(I);
    H = Ihsv(:,:,1);
    S = Ihsv(:,:,2);
    V = Ihsv(:,:,3);

    redMask = ( (H >= params.hueLow1 & H <= params.hueHigh1) | ...
                (H >= params.hueLow2 & H <= params.hueHigh2) ) & ...
               (S >= params.satMin) & (V >= params.valMin);

    redMask = imfill(redMask, 'holes');
    redMask = bwareaopen(redMask, params.minArea);

    se1 = strel('disk', 4);
    se2 = strel('disk', 8);
    redMask = imopen(redMask, se1);
    redMask = imclose(redMask, se2);
    redMask = imfill(redMask, 'holes');

    % ---------------- KEEP MAIN PILE ONLY ----------------
    cc = bwconncomp(redMask);
    if cc.NumObjects == 0
        error('No red region detected in %s.', imgPath);
    end

    stats = regionprops(cc, 'Area', 'BoundingBox');
    areas = [stats.Area];

    % Bias selection slightly toward components near the bottom
    [rows, cols] = size(redMask); %#ok<NASGU>
    scores = zeros(size(areas));
    for k = 1:numel(stats)
        bb = stats(k).BoundingBox; % [x y width height]
        yBottom = bb(2) + bb(4);
        scores(k) = areas(k) + 0.001 * yBottom;
    end
    [~, idxBest] = max(scores);

    pileMask = false(size(redMask));
    pileMask(cc.PixelIdxList{idxBest}) = true;
    pileMask = imclose(pileMask, strel('disk', 10));
    pileMask = imfill(pileMask, 'holes');

    % ---------------- EXTRACT UPPER BOUNDARY ----------------
    [~, nCols] = size(pileMask);
    xVals = [];
    yTop = [];

    for x = 1:nCols
        y = find(pileMask(:,x), 1, 'first');
        if ~isempty(y)
            xVals(end+1) = x; %#ok<AGROW>
            yTop(end+1) = y; %#ok<AGROW>
        end
    end

    if numel(xVals) < 30
        error('Not enough boundary points in %s.', imgPath);
    end

    yTopSmooth = smoothdata(yTop, 'sgolay', params.sgolayWindow);

    % ---------------- FIND APEX ----------------
    [~, apexIdx] = min(yTopSmooth);
    xApex = xVals(apexIdx);

    % ---------------- SPLIT LEFT / RIGHT ----------------
    leftMask = xVals < (xApex - params.excludeApexPixels);
    rightMask = xVals > (xApex + params.excludeApexPixels);

    xLeft = xVals(leftMask);
    yLeft = yTopSmooth(leftMask);
    xRight = xVals(rightMask);
    yRight = yTopSmooth(rightMask);

    if numel(xLeft) < 20 || numel(xRight) < 20
        error('Insufficient points on one or both sides in %s.', imgPath);
    end

    % ---------------- SLIDING-WINDOW LINEAR FIT (each side) ----------------
    [mLeft, R2Left, xLeftFit, yLeftFit] = bestLinearSegment( ...
        xLeft, yLeft, params.slideWindowMinPts, params.slideWindowMaxPts);

    [mRight, R2Right, xRightFit, yRightFit] = bestLinearSegment( ...
        xRight, yRight, params.slideWindowMinPts, params.slideWindowMaxPts);

    % ---------------- CONVERT SLOPES TO ANGLES ----------------
    thetaLeft  = atan(abs(mLeft))  * 180/pi;
    thetaRight = atan(abs(mRight)) * 180/pi;
    thetaMean  = (thetaLeft + thetaRight)/2;
    deltaThetaLR = abs(thetaLeft - thetaRight);

    % ---------------- BUILD RESULT STRUCT ----------------
    result = struct();
    result.imgPath = imgPath;
    result.thetaLeft = thetaLeft;
    result.thetaRight = thetaRight;
    result.thetaMean = thetaMean;
    result.mLeft = mLeft;
    result.mRight = mRight;
    result.R2Left = R2Left;
    result.R2Right = R2Right;
    result.deltaThetaLR = deltaThetaLR;
    result.nBoundaryPoints = numel(xVals);
    result.xBoundary = xVals;
    result.yBoundary = yTopSmooth;
    result.xLeftFit = xLeftFit;
    result.yLeftFit = yLeftFit;
    result.xRightFit = xRightFit;
    result.yRightFit = yRightFit;

    % ---------------- OPTIONAL PLOTS ----------------
    if params.showPlots
        figure('Name', sprintf('AoR Fit: %s', imgPath), 'NumberTitle','off');
        imshow(I); hold on;
        title(sprintf('%s | AoR = %.2f° (L=%.2f°, R=%.2f°)', ...
            imgPath, thetaMean, thetaLeft, thetaRight), 'Interpreter','none');

        plot(xVals, yTopSmooth, 'c-', 'LineWidth', 2);
        plot(xApex, yTopSmooth(apexIdx), 'yo', 'MarkerSize', 8, 'LineWidth', 2);

        % Left fitted line
        xLineLeft = linspace(min(xLeftFit), max(xLeftFit), 100);
        bLeft = mean(yLeftFit - mLeft * xLeftFit);
        yLineLeft = mLeft * xLineLeft + bLeft;
        plot(xLineLeft, yLineLeft, 'g-', 'LineWidth', 2);

        % Right fitted line
        xLineRight = linspace(min(xRightFit), max(xRightFit), 100);
        bRight = mean(yRightFit - mRight * xRightFit);
        yLineRight = mRight * xLineRight + bRight;
        plot(xLineRight, yLineRight, 'm-', 'LineWidth', 2);

        legend('Boundary', 'Apex', 'Left segment', 'Right segment', ...
               'Location','southoutside');
        hold off;
    end
end


function [mBest, R2Best, xBest, yBest] = bestLinearSegment(x, y, minPts, maxPts)
% bestLinearSegment  Find boundary segment with highest R^2 linear fit.
%
%   Slides a window along (x,y) for window length in [minPts, maxPts],
%   returns slope mBest, best R^2, and the corresponding segment (xBest, yBest).

    n = numel(x);
    minPts = min(minPts, n);
    maxPts = min(maxPts, n);

    R2Best = -Inf;
    mBest = NaN;
    xBest = [];
    yBest = [];

    for win = minPts:maxPts
        for iStart = 1:(n - win + 1)
            idx = iStart:(iStart + win - 1);
            xw = x(idx);
            yw = y(idx);

            p = polyfit(xw, yw, 1);
            yfit = polyval(p, xw);
            SSres = sum((yw - yfit).^2);
            SStot = sum((yw - mean(yw)).^2);
            R2 = 1 - SSres / SStot;

            if R2 > R2Best
                R2Best = R2;
                mBest = p(1);
                xBest = xw;
                yBest = yw;
            end
        end
    end
end
