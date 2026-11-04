`timescale 1ns/1ps

// Robust rectangle / circle recogniser for the final demo task.
//
// The earlier version used only a bounding box and a corner-pixel ratio.  It
// could be fooled by background edges, a noisy border, or a thick Sobel edge.
// This version uses three independent geometric measurements and classifies by
// majority vote:
//
//   1. perimeter density
//        |Gx| + |Gy| edge pixels / (width + height)
//        A rectangle is roughly 2*(w+h); a circle is roughly pi/2*(w+h).
//
//   2. longest horizontal edge run
//        A rectangle has long horizontal top/bottom sides.  A circle only
//        crosses most scanlines in two short places, so its longest horizontal
//        run stays small even when its diameter is large.
//
//   3. corner occupancy
//        A rectangle fills its bounding-box corners; a circle touches its
//        bounding box at the side midpoints, so its corner windows are nearly
//        empty.
//
// Two or more features vote for a rectangle.  Otherwise the contour is
// reported as a circle when the frame has enough valid edge pixels.
//
// The input is the raw Sobel magnitude / 8, so shape recognition does not move
// with the manual edge threshold used by tasks 2..5.
module VIP_ShapeOverlay #(
    parameter [13:0] IMG_HDISP = 14'd1920,
    parameter [13:0] IMG_VDISP = 14'd1080,
    parameter [7:0]  EDGE_THRESHOLD = 8'd8,
    parameter [13:0] ROI_MARGIN_X = 14'd32,
    parameter [13:0] ROI_MARGIN_Y = 14'd18,
    parameter [1:0]  MAX_RUN_GAP = 2'd1
    )(
    input               clk,
    input               rst_n,

    input               per_frame_vsync,
    input               per_frame_href,
    input               per_frame_hsync,
    input               per_img_edge,
    input       [7:0]   per_img_grad,
    input       [7:0]   per_img_red,
    input       [7:0]   per_img_green,
    input       [7:0]   per_img_blue,

    output reg          post_frame_vsync,
    output reg          post_frame_href,
    output reg          post_frame_hsync,
    output reg  [7:0]   post_img_red,
    output reg  [7:0]   post_img_green,
    output reg  [7:0]   post_img_blue,
    output reg  [1:0]   shape_type       // 0 unknown, 1 rectangle, 2 circle
    );

    localparam [13:0] ROI_X0 = ROI_MARGIN_X;
    localparam [13:0] ROI_X1 = IMG_HDISP - ROI_MARGIN_X - 1'b1;
    localparam [13:0] ROI_Y0 = ROI_MARGIN_Y;
    localparam [13:0] ROI_Y1 = IMG_VDISP - ROI_MARGIN_Y - 1'b1;
    // Large R / C letters make the recognition result readable on the
    // monitor without needing a complete font generator.
    localparam [13:0] LABEL_X = 14'd80;
    localparam [13:0] LABEL_Y = 14'd64;
    localparam [13:0] LABEL_W = 14'd80;
    localparam [13:0] LABEL_H = 14'd112;

    reg [13:0] x_cnt;
    reg [13:0] y_cnt;
    reg        href_d;
    reg        vsync_d;

    wire href_rise   = per_frame_href && !href_d;
    wire vsync_fall  = vsync_d && !per_frame_vsync;
    wire pixel_valid = per_frame_href && per_frame_vsync;
    wire in_roi      = pixel_valid &&
                       (x_cnt >= ROI_X0) && (x_cnt <= ROI_X1) &&
                       (y_cnt >= ROI_Y0) && (y_cnt <= ROI_Y1);
    // Use the thresholded Sobel edge as the confirmed contour, and keep a
    // low-gradient fallback so a slightly weak but continuous outline still
    // reaches the geometric feature stage.
    wire edge_pixel  = in_roi &&
                       (per_img_edge || (per_img_grad > EDGE_THRESHOLD));

    // Current-frame statistics.
    reg [13:0] min_x, max_x, min_y, max_y;
    reg [21:0] edge_count;
    reg [21:0] corner_count;

    // Horizontal run tracker.  One missing pixel is tolerated so a slightly
    // broken edge line does not destroy the measurement.
    reg [13:0] run_len;
    reg [1:0]  run_gap;
    reg [13:0] max_run;

    // Latched detection box and type.
    reg [13:0] box_min_x, box_max_x, box_min_y, box_max_y;
    reg        box_valid;
    reg [1:0]  box_type;

    // Coordinate counters: vsync is HIGH while the active picture is valid.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_cnt   <= 14'd0;
            y_cnt   <= 14'd0;
            href_d  <= 1'b0;
            vsync_d <= 1'b0;
        end else begin
            href_d  <= per_frame_href;
            vsync_d <= per_frame_vsync;

            if (per_frame_href) begin
                if (x_cnt < IMG_HDISP - 1'b1)
                    x_cnt <= x_cnt + 1'b1;
            end else begin
                x_cnt <= 14'd0;
            end

            if (href_rise && per_frame_vsync) begin
                if (y_cnt < IMG_VDISP - 1'b1)
                    y_cnt <= y_cnt + 1'b1;
            end else if (!per_frame_vsync) begin
                y_cnt <= 14'd0;
            end
        end
    end

    // Horizontal run length.  The longest run is reset at every frame end.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            run_len <= 14'd0;
            run_gap <= 2'd0;
            max_run <= 14'd0;
        end else if (vsync_fall) begin
            run_len <= 14'd0;
            run_gap <= 2'd0;
            max_run <= 14'd0;
        end else if (!per_frame_href) begin
            run_len <= 14'd0;
            run_gap <= 2'd0;
        end else if (in_roi) begin
            if (edge_pixel) begin
                if (run_len == 14'd0) begin
                    run_len <= 14'd1;
                    run_gap <= 2'd0;
                    if (max_run < 14'd1)
                        max_run <= 14'd1;
                end else begin
                    run_len <= run_len + {12'd0, run_gap} + 1'b1;
                    run_gap <= 2'd0;
                    if ((run_len + {12'd0, run_gap} + 1'b1) > max_run)
                        max_run <= run_len + {12'd0, run_gap} + 1'b1;
                end
            end else if ((run_len != 14'd0) && (run_gap < MAX_RUN_GAP)) begin
                run_gap <= run_gap + 1'b1;
            end else begin
                run_len <= 14'd0;
                run_gap <= 2'd0;
            end
        end
    end

    // Previous-frame bounding box corner windows.  These are evaluated while
    // scanning the current frame, so the object must be reasonably still for
    // one frame; the other two features still work if the object moves.
    wire [13:0] box_w = box_max_x - box_min_x;
    wire [13:0] box_h = box_max_y - box_min_y;
    wire [13:0] corner_w = (box_w >> 3) + 14'd2;
    wire [13:0] corner_h = (box_h >> 3) + 14'd2;

    wire in_corner_tl = box_valid &&
                        (x_cnt >= box_min_x) && (x_cnt <= box_min_x + corner_w) &&
                        (y_cnt >= box_min_y) && (y_cnt <= box_min_y + corner_h);
    wire in_corner_tr = box_valid &&
                        (x_cnt >= box_max_x - corner_w) && (x_cnt <= box_max_x) &&
                        (y_cnt >= box_min_y) && (y_cnt <= box_min_y + corner_h);
    wire in_corner_bl = box_valid &&
                        (x_cnt >= box_min_x) && (x_cnt <= box_min_x + corner_w) &&
                        (y_cnt >= box_max_y - corner_h) && (y_cnt <= box_max_y);
    wire in_corner_br = box_valid &&
                        (x_cnt >= box_max_x - corner_w) && (x_cnt <= box_max_x) &&
                        (y_cnt >= box_max_y - corner_h) && (y_cnt <= box_max_y);
    wire in_corner = in_corner_tl || in_corner_tr || in_corner_bl || in_corner_br;

    wire [13:0] cur_w = max_x - min_x;
    wire [13:0] cur_h = max_y - min_y;
    wire [14:0] cur_sum = {1'b0, cur_w} + {1'b0, cur_h};
    wire        box_size_ok = (min_x != 14'h3FFF) &&
                              (cur_w >= 14'd8) && (cur_h >= 14'd8) &&
                              (edge_count >= 22'd8);

    // Feature 1: perimeter density.  A rectangle has substantially more
    // outline pixels than a circle with the same bounding box.
    wire [14:0] edge_limit = cur_sum + (cur_sum >> 1) + (cur_sum >> 2); // 1.75x
    wire        rect_by_count = edge_count > {7'd0, edge_limit};

    // Feature 2: longest horizontal run.  A rectangle's top/bottom side is a
    // long run; a circle's scanline intersections are short.
    wire [13:0] run_limit = (cur_w >> 2);
    wire        rect_by_run = max_run > run_limit;

    // Feature 3: corner occupancy.  A rectangle fills its box corners; a
    // circle does not.
    wire [14:0] corner_limit = cur_sum >> 2;
    wire        rect_by_corner = corner_count > {7'd0, corner_limit};

    wire [2:0] rect_votes = {2'b00, rect_by_count} +
                            {2'b00, rect_by_run} +
                            {2'b00, rect_by_corner};

    wire [1:0] detected_type = !box_size_ok          ? 2'd0 :
                               (rect_votes >= 3'd2)  ? 2'd1 : 2'd2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            min_x        <= 14'h3FFF;
            max_x        <= 14'd0;
            min_y        <= 14'h3FFF;
            max_y        <= 14'd0;
            edge_count   <= 22'd0;
            corner_count <= 22'd0;
            box_min_x    <= 14'd0;
            box_max_x    <= 14'd0;
            box_min_y    <= 14'd0;
            box_max_y    <= 14'd0;
            box_valid    <= 1'b0;
            box_type     <= 2'd0;
        end else if (vsync_fall) begin
            box_min_x  <= min_x;
            box_max_x  <= max_x;
            box_min_y  <= min_y;
            box_max_y  <= max_y;
            box_valid  <= box_size_ok;
            box_type   <= detected_type;

            min_x        <= 14'h3FFF;
            max_x        <= 14'd0;
            min_y        <= 14'h3FFF;
            max_y        <= 14'd0;
            edge_count   <= 22'd0;
            corner_count <= 22'd0;
        end else if (edge_pixel) begin
            edge_count <= edge_count + 1'b1;
            if (in_corner)
                corner_count <= corner_count + 1'b1;
            if (x_cnt < min_x) min_x <= x_cnt;
            if (x_cnt > max_x) max_x <= x_cnt;
            if (y_cnt < min_y) min_y <= y_cnt;
            if (y_cnt > max_y) max_y <= y_cnt;
        end
    end

    // Draw the detection box over the delayed colour image.
    wire in_box_x = box_valid && (x_cnt >= box_min_x) && (x_cnt <= box_max_x);
    wire in_box_y = box_valid && (y_cnt >= box_min_y) && (y_cnt <= box_max_y);
    wire box_left   = in_box_y && (x_cnt == box_min_x || x_cnt == box_min_x + 1'b1);
    wire box_right  = in_box_y && (x_cnt == box_max_x || x_cnt == box_max_x - 1'b1);
    wire box_top    = in_box_x && (y_cnt == box_min_y || y_cnt == box_min_y + 1'b1);
    wire box_bottom = in_box_x && (y_cnt == box_max_y || y_cnt == box_max_y - 1'b1);
    wire box_pixel  = box_left || box_right || box_top || box_bottom;

    // Circle outline.  The circle uses the average of the box radii; a
    // detected circle is nearly square in its bounding box.  The squared
    // distance keeps this a simple streaming comparison.
    wire [13:0] box_cx = (box_min_x + box_max_x) >> 1;
    wire [13:0] box_cy = (box_min_y + box_max_y) >> 1;
    wire [13:0] box_rx = (box_max_x - box_min_x) >> 1;
    wire [13:0] box_ry = (box_max_y - box_min_y) >> 1;
    wire [13:0] box_r  = (box_rx + box_ry) >> 1;
    wire [13:0] box_dx = (x_cnt >= box_cx) ? (x_cnt - box_cx) : (box_cx - x_cnt);
    wire [13:0] box_dy = (y_cnt >= box_cy) ? (y_cnt - box_cy) : (box_cy - y_cnt);
    wire [27:0] box_d2 = (box_dx * box_dx) + (box_dy * box_dy);
    wire [27:0] box_r2 = box_r * box_r;
    wire [27:0] box_band = box_r * 4;
    wire [27:0] box_lo = (box_r2 > box_band) ? (box_r2 - box_band) : 28'd0;
    wire        circle_pixel = box_valid && (box_type == 2'd2) &&
                               (box_d2 >= box_lo) &&
                               (box_d2 <= (box_r2 + box_band));

    // 5x7 R/C glyph, scaled x16.  The bit index is valid only when the
    // label window and the glyph row/column are inside the pattern.
    localparam [34:0] GLYPH_R = 35'b11110_10001_10001_11110_10100_10010_10001;
    localparam [34:0] GLYPH_C = 35'b01111_10000_10000_10000_10000_10000_01111;

    wire label_area_x = (x_cnt >= LABEL_X) && (x_cnt < LABEL_X + LABEL_W);
    wire label_area_y = (y_cnt >= LABEL_Y) && (y_cnt < LABEL_Y + LABEL_H);
    wire [3:0] glyph_col = (x_cnt - LABEL_X) >> 4;
    wire [3:0] glyph_row = (y_cnt - LABEL_Y) >> 4;
    wire [5:0] glyph_index = ({2'b00, glyph_row} * 6'd5) +
                             {2'b00, glyph_col};
    wire [34:0] glyph_bits = (box_type == 2'd2) ? GLYPH_C : GLYPH_R;
    wire glyph_on = box_valid && (box_type != 2'd0) &&
                    label_area_x && label_area_y &&
                    (glyph_row < 4'd7) && (glyph_col < 4'd5) &&
                    glyph_bits[6'd34 - glyph_index];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            post_frame_vsync <= 1'b0;
            post_frame_href  <= 1'b0;
            post_frame_hsync <= 1'b0;
            post_img_red     <= 8'd0;
            post_img_green   <= 8'd0;
            post_img_blue    <= 8'd0;
            shape_type       <= 2'd0;
        end else begin
            post_frame_vsync <= per_frame_vsync;
            post_frame_href  <= per_frame_href;
            post_frame_hsync <= per_frame_hsync;

            if (glyph_on && (box_type == 2'd1)) begin
                post_img_red   <= 8'hFF;   // "R" label: yellow
                post_img_green <= 8'hFF;
                post_img_blue  <= 8'h00;
            end else if (glyph_on && (box_type == 2'd2)) begin
                post_img_red   <= 8'h00;   // "C" label: cyan
                post_img_green <= 8'hFF;
                post_img_blue  <= 8'hFF;
            end else if (box_pixel && (box_type == 2'd1)) begin
                post_img_red   <= 8'hFF;   // rectangle: yellow
                post_img_green <= 8'hFF;
                post_img_blue  <= 8'h00;
            end else if (circle_pixel) begin
                post_img_red   <= 8'h00;   // circle: cyan
                post_img_green <= 8'hFF;
                post_img_blue  <= 8'hFF;
            end else if (box_pixel) begin
                post_img_red   <= 8'hFF;   // detected but not classified
                post_img_green <= 8'hFF;
                post_img_blue  <= 8'hFF;
            end else if (edge_pixel) begin
                post_img_red   <= 8'hFF;   // highlight the measured contour
                post_img_green <= 8'hFF;
                post_img_blue  <= 8'hFF;
            end else begin
                post_img_red   <= per_img_red;
                post_img_green <= per_img_green;
                post_img_blue  <= per_img_blue;
            end

            shape_type <= box_type;
        end
    end

endmodule
