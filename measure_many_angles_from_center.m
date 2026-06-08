

function measure_many_angles_from_center(imageFile)
    % Measure many angles from one selected center and one reference direction
    %
    % Usage:
    % measure_many_angles_from_center('IMG_0834.jpg')

    I = imread("green_v_green.png");

    figure('Name','Measure Many Angles From Center','NumberTitle','off');
    imshow(I); hold on; axis image;

    title({'Step 1: Click the circle center once.'});
    [xc, yc] = ginput(1);
    plot(xc, yc, 'ro', 'MarkerFaceColor','r', 'MarkerSize', 8);

    title({'Step 2: Click one reference point for 0 degrees.'});
    [x0, y0] = ginput(1);
    plot([xc x0], [yc y0], 'g-', 'LineWidth', 2);
    plot(x0, y0, 'go', 'MarkerFaceColor','g', 'MarkerSize', 8);

    refAngle = atan2(-(y0 - yc), (x0 - xc));

    title({'Step 3: Click as many target points as you want.', ...
           'Press Enter when finished.'});
    [x, y] = ginput();

    n = numel(x);
    anglesDeg = zeros(n,1);

    for i = 1:n
        ang = atan2(-(y(i) - yc), (x(i) - xc));
        anglesDeg(i) = mod(rad2deg(ang - refAngle), 360);

        plot([xc x(i)], [yc y(i)], 'y-');
        plot(x(i), y(i), 'yo', 'MarkerFaceColor','y', 'MarkerSize', 6);

        label = sprintf('%d: %.2f°', i, anglesDeg(i));
        text(x(i), y(i), ['  ' label], ...
            'Color','y', 'FontSize',11, 'FontWeight','bold');
    end

    T = table((1:n)', x, y, anglesDeg, ...
        'VariableNames', {'PointNumber','X','Y','AngleDeg'});

    disp(T);

    assignin('base','measured_angles_table',T);
    assignin('base','measured_angles_deg',anglesDeg);

    title('Done: angles shown on image and saved to workspace');
end