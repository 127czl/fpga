`timescale 1ns/1ps

// Task 9, v81: conservative multi-target detector derived from the v79c
// single-target row-band/column-projection pipeline.
//
// Detection remains stream based:
//   1. find the strongest continuous vertical row band;
//   2. retain up to four separated column runs inside that band;
//   3. verify every candidate on the following frame using Sobel edge density.
//
// Classification uses perimeter density instead of horizontal span, so a
// mildly rotated rectangle does not turn into a circle and vice versa.
module VIP_CCLShapeOverlay #(
    parameter [13:0] IMG_HDISP = 14'd1920,
    parameter [13:0] IMG_VDISP = 14'd1080,
    parameter [13:0] ROI_X0 = 14'd160,
    parameter [13:0] ROI_X1 = 14'd1759,
    parameter [13:0] ROI_Y0 = 14'd40,
    parameter [13:0] ROI_Y1 = 14'd1039,
    parameter [31:0] MIN_BOX_AREA = 32'd64800,
    parameter [31:0] MAX_BOX_AREA = 32'd1000000,
    parameter [13:0] MIN_SIDE = 14'd120,
    parameter [13:0] MAX_SIDE = 14'd1000,
    parameter [13:0] BOUNDARY_GUARD = 14'd8
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
    input       [1:0]   cfg_roi_level,
    output reg          post_frame_vsync,
    output reg          post_frame_href,
    output reg          post_frame_hsync,
    output reg  [7:0]   post_img_red,
    output reg  [7:0]   post_img_green,
    output reg  [7:0]   post_img_blue,
    output reg  [1:0]   shape_type,
    output wire [3:0]   circle_count_out,
    output wire [3:0]   rect_count_out
    );

    localparam [8:0] COL_N = 9'd400;
    localparam [11:0] ROW_EDGE_MIN = 12'd4;
    localparam [13:0] ROW_SPAN_MIN = 14'd60;
    localparam [11:0] MIN_ACTIVE_ROWS = 12'd60;
    localparam [3:0] COL_HIT_MIN = 4'd3;
    localparam [1:0] COL_GAP_MAX = 2'd1;
    localparam [8:0] COL_RUN_MIN = 9'd30;

    localparam [2:0] S_CLEAR = 3'd0;
    localparam [2:0] S_WAIT  = 3'd1;
    localparam [2:0] S_SCAN  = 3'd2;
    localparam [2:0] S_CLOSE = 3'd3;
    localparam [2:0] S_APPLY = 3'd4;

    reg [13:0] x_cnt, y_cnt;
    reg [13:0] roi_x0, roi_x1, roi_y0, roi_y1;
    reg [1:0] roi_level_active;
    reg href_d, vsync_d;
    wire href_rise = per_frame_href && !href_d;
    wire vsync_rise = per_frame_vsync && !vsync_d;
    wire vsync_fall = vsync_d && !per_frame_vsync;
    wire line_end = href_d && !per_frame_href;
    always @(*) begin
        case (roi_level_active)
            2'd1: begin
                roi_x0 = 14'd320;  roi_x1 = 14'd1599;
                roi_y0 = 14'd140;  roi_y1 = 14'd939;
            end
            2'd2: begin
                roi_x0 = 14'd480;  roi_x1 = 14'd1439;
                roi_y0 = 14'd240;  roi_y1 = 14'd839;
            end
            2'd3: begin
                roi_x0 = 14'd600;  roi_x1 = 14'd1319;
                roi_y0 = 14'd315;  roi_y1 = 14'd764;
            end
            default: begin
                roi_x0 = ROI_X0;   roi_x1 = ROI_X1;
                roi_y0 = ROI_Y0;   roi_y1 = ROI_Y1;
            end
        endcase
    end

    wire in_roi = per_frame_href && per_frame_vsync &&
                  (x_cnt >= roi_x0) && (x_cnt <= roi_x1) &&
                  (y_cnt >= roi_y0) && (y_cnt <= roi_y1);
    wire edge_pix = in_roi && per_img_edge;
    wire [8:0] col_index = (x_cnt - roi_x0) >> 2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_cnt <= 14'd0;
            y_cnt <= 14'd0;
            roi_level_active <= 2'd0;
            href_d <= 1'b0;
            vsync_d <= 1'b0;
        end else begin
            href_d <= per_frame_href;
            vsync_d <= per_frame_vsync;
            if (vsync_rise)
                roi_level_active <= cfg_roi_level;
            if (per_frame_href) begin
                if (x_cnt < IMG_HDISP - 1'b1)
                    x_cnt <= x_cnt + 1'b1;
            end else
                x_cnt <= 14'd0;
            if (href_rise && per_frame_vsync) begin
                if (y_cnt < IMG_VDISP - 1'b1)
                    y_cnt <= y_cnt + 1'b1;
            end else if (!per_frame_vsync)
                y_cnt <= 14'd0;
        end
    end

    reg [2:0] meta_state;
    reg [8:0] scan_idx, clear_idx;
    reg [3:0] col_hits [0:COL_N-1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            meta_state <= S_CLEAR;
            scan_idx <= 9'd0;
            clear_idx <= 9'd0;
        end else begin
            if ((meta_state == S_WAIT) && vsync_fall) begin
                scan_idx <= 9'd0;
                meta_state <= S_SCAN;
            end else begin
                case (meta_state)
                    S_CLEAR: begin
                        col_hits[clear_idx] <= 4'd0;
                        if (clear_idx == COL_N - 1'b1) begin
                            clear_idx <= 9'd0;
                            meta_state <= S_WAIT;
                        end else
                            clear_idx <= clear_idx + 1'b1;
                    end
                    S_WAIT: ;
                    S_SCAN: begin
                        col_hits[scan_idx] <= 4'd0;
                        if (scan_idx == COL_N - 1'b1) begin
                            scan_idx <= 9'd0;
                            meta_state <= S_CLOSE;
                        end else
                            scan_idx <= scan_idx + 1'b1;
                    end
                    S_CLOSE: meta_state <= S_APPLY;
                    S_APPLY: meta_state <= S_WAIT;
                    default: meta_state <= S_CLEAR;
                endcase
            end

            if (meta_state == S_WAIT && edge_pix && col_index < COL_N) begin
                if (col_hits[col_index] != 4'hF)
                    col_hits[col_index] <= col_hits[col_index] + 1'b1;
            end
        end
    end

    reg [11:0] row_count;
    reg [13:0] row_x0, row_x1, row_y;
    wire [13:0] row_span =
        (row_count != 0 && row_x1 >= row_x0) ?
        (row_x1 - row_x0 + 1'b1) : 14'd0;

    reg band_valid;
    reg [11:0] band_rows;
    reg [13:0] band_y0, band_y1;
    reg best_band_valid;
    reg [11:0] best_band_rows;
    reg [13:0] best_band_y0, best_band_y1;
    reg frame_row_valid;
    reg [13:0] frame_y0, frame_y1;

    reg col_active;
    reg [1:0] col_gap;
    reg [8:0] active_col_x0, active_col_x1;
    reg col_valid [0:3];
    reg [8:0] col_x0 [0:3];
    reg [8:0] col_x1 [0:3];

    reg cand_valid [0:3];
    reg [13:0] cand_x0 [0:3];
    reg [13:0] cand_x1 [0:3];
    reg [13:0] cand_y0 [0:3];
    reg [13:0] cand_y1 [0:3];
    reg [13:0] cand_cx [0:3];
    reg [13:0] cand_cy [0:3];
    reg [27:0] cand_r2 [0:3];
    reg [15:0] cand_edge_count [0:3];
    reg [15:0] cand_bad_count [0:3];
    reg [31:0] cand_span_sum [0:3];
    reg [11:0] cand_row_count [0:3];
    reg [13:0] cand_row_x0 [0:3];
    reg [13:0] cand_row_x1 [0:3];

    reg draw_valid [0:3];
    reg [1:0] draw_type [0:3];
    reg [13:0] draw_x0 [0:3];
    reg [13:0] draw_x1 [0:3];
    reg [13:0] draw_y0 [0:3];
    reg [13:0] draw_y1 [0:3];

    reg c1_valid [0:3];
    reg [13:0] c1_dx [0:3];
    reg [13:0] c1_dy [0:3];
    reg [13:0] c1_x [0:3];
    reg [13:0] c1_y [0:3];

    reg c2_valid [0:3];
    reg [27:0] c2_d2 [0:3];
    reg [13:0] c2_x [0:3];
    reg [13:0] c2_y [0:3];

    reg line_end_d1, line_end_d2, line_end_d3;
    reg [13:0] row_y_d1, row_y_d2, row_y_d3;

    integer n;
    integer j;

    task insert_col_run;
        input [8:0] x0;
        input [8:0] x1;
        reg [8:0] len;
        reg [8:0] len0, len1, len2;
        begin
            len = x1 - x0 + 1'b1;
            if (len >= COL_RUN_MIN) begin
                len0 = col_x1[0] - col_x0[0] + 1'b1;
                len1 = col_x1[1] - col_x0[1] + 1'b1;
                len2 = col_x1[2] - col_x0[2] + 1'b1;
                if (!col_valid[0] || (len > len0)) begin
                    col_valid[3] <= col_valid[2];
                    col_x0[3] <= col_x0[2];
                    col_x1[3] <= col_x1[2];
                    col_valid[2] <= col_valid[1];
                    col_x0[2] <= col_x0[1];
                    col_x1[2] <= col_x1[1];
                    col_valid[1] <= col_valid[0];
                    col_x0[1] <= col_x0[0];
                    col_x1[1] <= col_x1[0];
                    col_valid[0] <= 1'b1;
                    col_x0[0] <= x0;
                    col_x1[0] <= x1;
                end else if (!col_valid[1] || (len > len0)) begin
                    col_valid[3] <= col_valid[2];
                    col_x0[3] <= col_x0[2];
                    col_x1[3] <= col_x1[2];
                    col_valid[2] <= col_valid[1];
                    col_x0[2] <= col_x0[1];
                    col_x1[2] <= col_x1[1];
                    col_valid[1] <= 1'b1;
                    col_x0[1] <= x0;
                    col_x1[1] <= x1;
                end else if (!col_valid[2] || (len > len1)) begin
                    col_valid[3] <= col_valid[2];
                    col_x0[3] <= col_x0[2];
                    col_x1[3] <= col_x1[2];
                    col_valid[2] <= 1'b1;
                    col_x0[2] <= x0;
                    col_x1[2] <= x1;
                end else if (!col_valid[3] || (len > len2)) begin
                    col_valid[3] <= 1'b1;
                    col_x0[3] <= x0;
                    col_x1[3] <= x1;
                end
            end
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_count <= 12'd0;
            row_x0 <= 14'd0;
            row_x1 <= 14'd0;
            row_y <= 14'd0;
            band_valid <= 1'b0;
            band_rows <= 12'd0;
            band_y0 <= 14'd0;
            band_y1 <= 14'd0;
            best_band_valid <= 1'b0;
            best_band_rows <= 12'd0;
            best_band_y0 <= 14'd0;
            best_band_y1 <= 14'd0;
            frame_row_valid <= 1'b0;
            frame_y0 <= 14'd0;
            frame_y1 <= 14'd0;
            col_active <= 1'b0;
            col_gap <= 2'd0;
            active_col_x0 <= 9'd0;
            active_col_x1 <= 9'd0;
            for (n = 0; n < 4; n = n + 1) begin
                col_valid[n] <= 1'b0;
                col_x0[n] <= 9'd0;
                col_x1[n] <= 9'd0;
                cand_valid[n] <= 1'b0;
                cand_x0[n] <= 14'd0;
                cand_x1[n] <= 14'd0;
                cand_y0[n] <= 14'd0;
                cand_y1[n] <= 14'd0;
                cand_cx[n] <= 14'd0;
                cand_cy[n] <= 14'd0;
                cand_r2[n] <= 28'd0;
                draw_valid[n] <= 1'b0;
                draw_type[n] <= 2'd0;
                draw_x0[n] <= 14'd0;
                draw_x1[n] <= 14'd0;
                draw_y0[n] <= 14'd0;
                draw_y1[n] <= 14'd0;
            end
        end else begin
            if (vsync_rise) begin
                band_valid <= 1'b0;
                band_rows <= 12'd0;
                best_band_valid <= 1'b0;
                best_band_rows <= 12'd0;
            end

            if (edge_pix) begin
                if (row_count == 0) begin
                    row_x0 <= x_cnt;
                    row_x1 <= x_cnt;
                    row_y <= y_cnt;
                end else begin
                    if (x_cnt < row_x0) row_x0 <= x_cnt;
                    if (x_cnt > row_x1) row_x1 <= x_cnt;
                end
                row_count <= row_count + 1'b1;
            end

            if (line_end) begin
                if ((row_count >= ROW_EDGE_MIN) &&
                    (row_span >= ROW_SPAN_MIN)) begin
                    band_valid <= 1'b1;
                    band_rows <= band_rows + 1'b1;
                    if (band_rows == 0) begin
                        band_y0 <= row_y;
                        band_y1 <= row_y;
                    end else begin
                        if (row_y < band_y0) band_y0 <= row_y;
                        if (row_y > band_y1) band_y1 <= row_y;
                    end
                end else if (band_valid) begin
                    if ((band_rows >= MIN_ACTIVE_ROWS) &&
                        (!best_band_valid ||
                         (band_rows > best_band_rows))) begin
                        best_band_valid <= 1'b1;
                        best_band_rows <= band_rows;
                        best_band_y0 <= band_y0;
                        best_band_y1 <= band_y1;
                    end
                    band_valid <= 1'b0;
                    band_rows <= 12'd0;
                end

                row_count <= 12'd0;
            end

            if (vsync_fall) begin
                // Verify previous candidates using edge density, which is
                // almost invariant to rectangle rotation.
                for (n = 0; n < 4; n = n + 1) begin
                    begin : classify_candidate
                        reg [13:0] w, h;
                        reg [27:0] box_area;
                        reg square_enough;
                        reg radial_circle;
                        reg radial_rect;
                        reg span_circle;
                        reg span_rect;
                        reg rotated_aspect_ok;
                        reg valid_now;
                        reg [1:0] type_now;
                        w = (cand_x1[n] >= cand_x0[n]) ?
                            (cand_x1[n] - cand_x0[n] + 1'b1) : 14'd0;
                        h = (cand_y1[n] >= cand_y0[n]) ?
                            (cand_y1[n] - cand_y0[n] + 1'b1) : 14'd0;
                        box_area = w * h;
                        square_enough = (w * 5 >= h * 4) &&
                                        (h * 5 >= w * 4);
                        radial_circle = (cand_bad_count[n] * 10) <=
                                        cand_edge_count[n];
                        radial_rect = (cand_bad_count[n] * 5) >=
                                      cand_edge_count[n];
                        rotated_aspect_ok = (w * 2 >= h * 3) &&
                                            (h * 3 >= w * 2);
                        span_circle = (cand_span_sum[n] >=
                                       (box_area >> 1) + (box_area >> 3) +
                                       (box_area >> 4)) &&
                                      (cand_span_sum[n] <=
                                       box_area - (box_area >> 3));
                        span_rect = (cand_span_sum[n] >=
                                     box_area - (box_area >> 3)) ||
                                    ((cand_span_sum[n] >=
                                      (box_area >> 1) + (box_area >> 3)) &&
                                     (cand_span_sum[n] <
                                      box_area - (box_area >> 3) -
                                      (box_area >> 4)) &&
                                     rotated_aspect_ok);
                        valid_now = cand_valid[n] &&
                                    (cand_edge_count[n] >= 32) &&
                                    (w >= MIN_SIDE) && (h >= MIN_SIDE) &&
                                    (w <= MAX_SIDE) && (h <= MAX_SIDE) &&
                                    (box_area >= MIN_BOX_AREA) &&
                                    (box_area <= MAX_BOX_AREA) &&
                                    (cand_x0[n] > roi_x0 + BOUNDARY_GUARD) &&
                                    (cand_y0[n] > roi_y0 + BOUNDARY_GUARD) &&
                                    (cand_x1[n] < roi_x1 - BOUNDARY_GUARD) &&
                                    (cand_y1[n] < roi_y1 - BOUNDARY_GUARD);
                        type_now = !valid_now ? 2'd0 :
                                   (radial_rect && span_rect) ? 2'd1 :
                                   (square_enough && radial_circle &&
                                    span_circle) ? 2'd2 :
                                   2'd0;
                        draw_valid[n] <= (type_now != 2'd0);
                        draw_type[n] <= type_now;
                        draw_x0[n] <= cand_x0[n];
                        draw_x1[n] <= cand_x1[n];
                        draw_y0[n] <= cand_y0[n];
                        draw_y1[n] <= cand_y1[n];
                    end
                end

                if (band_valid &&
                    (band_rows >= MIN_ACTIVE_ROWS) &&
                    (!best_band_valid || (band_rows > best_band_rows))) begin
                    frame_row_valid <= 1'b1;
                    frame_y0 <= band_y0;
                    frame_y1 <= band_y1;
                end else begin
                    frame_row_valid <= best_band_valid;
                    frame_y0 <= best_band_y0;
                    frame_y1 <= best_band_y1;
                end

                if (meta_state == S_WAIT) begin
                    col_active <= 1'b0;
                    col_gap <= 2'd0;
                    for (n = 0; n < 4; n = n + 1)
                        col_valid[n] <= 1'b0;
                end
            end

            if (meta_state == S_SCAN) begin
                if (col_hits[scan_idx] >= COL_HIT_MIN) begin
                    if (!col_active) begin
                        col_active <= 1'b1;
                        active_col_x0 <= scan_idx;
                        active_col_x1 <= scan_idx;
                    end else
                        active_col_x1 <= scan_idx;
                    col_gap <= 2'd0;
                end else if (col_active) begin
                    if (col_gap < COL_GAP_MAX)
                        col_gap <= col_gap + 1'b1;
                    else begin
                        insert_col_run(active_col_x0, active_col_x1);
                        col_active <= 1'b0;
                        col_gap <= 2'd0;
                    end
                end
            end else if (meta_state == S_CLOSE) begin
                if (col_active)
                    insert_col_run(active_col_x0, active_col_x1);
                col_active <= 1'b0;
                col_gap <= 2'd0;
            end else if (meta_state == S_APPLY) begin
                for (n = 0; n < 4; n = n + 1) begin
                    begin : build_candidate
                        reg [13:0] fx0, fx1, fw, fh;
                        reg [13:0] fcx, fcy, frx, fry;
                        reg [27:0] farea;
                        fx0 = roi_x0 + ({5'd0, col_x0[n]} << 2);
                        fx1 = roi_x0 + ({5'd0, col_x1[n]} << 2) + 14'd3;
                        fw = fx1 - fx0 + 1'b1;
                        fh = frame_y1 - frame_y0 + 1'b1;
                        fcx = (fx0 + fx1) >> 1;
                        fcy = (frame_y0 + frame_y1) >> 1;
                        frx = fw >> 1;
                        fry = fh >> 1;
                        farea = fw * fh;
                        cand_valid[n] <= col_valid[n] && frame_row_valid &&
                            (fw >= MIN_SIDE) && (fh >= MIN_SIDE) &&
                            (fw <= MAX_SIDE) && (fh <= MAX_SIDE) &&
                            (farea >= MIN_BOX_AREA) &&
                            (farea <= MAX_BOX_AREA) &&
                            (fx0 > roi_x0 + BOUNDARY_GUARD) &&
                            (frame_y0 > roi_y0 + BOUNDARY_GUARD) &&
                            (fx1 < roi_x1 - BOUNDARY_GUARD) &&
                            (frame_y1 < roi_y1 - BOUNDARY_GUARD);
                        cand_x0[n] <= fx0;
                        cand_x1[n] <= fx1;
                        cand_y0[n] <= frame_y0;
                        cand_y1[n] <= frame_y1;
                        cand_cx[n] <= fcx;
                        cand_cy[n] <= fcy;
                        cand_r2[n] <= frx * fry;
                    end
                end
            end
        end
    end

    // Radial-distance and row-span measurement pipeline.  The square
    // multipliers are split across two stages so the 148.5 MHz pixel path
    // does not contain four multipliers, compares and counters at once.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            line_end_d1 <= 1'b0;
            line_end_d2 <= 1'b0;
            line_end_d3 <= 1'b0;
            row_y_d1 <= 14'd0;
            row_y_d2 <= 14'd0;
            row_y_d3 <= 14'd0;
            for (n = 0; n < 4; n = n + 1) begin
                c1_valid[n] <= 1'b0;
                c1_dx[n] <= 14'd0;
                c1_dy[n] <= 14'd0;
                c1_x[n] <= 14'd0;
                c1_y[n] <= 14'd0;
                c2_valid[n] <= 1'b0;
                c2_d2[n] <= 28'd0;
                c2_x[n] <= 14'd0;
                c2_y[n] <= 14'd0;
                cand_edge_count[n] <= 16'd0;
                cand_bad_count[n] <= 16'd0;
                cand_span_sum[n] <= 32'd0;
                cand_row_count[n] <= 12'd0;
                cand_row_x0[n] <= 14'd0;
                cand_row_x1[n] <= 14'd0;
            end
        end else begin
            line_end_d1 <= line_end;
            line_end_d2 <= line_end_d1;
            line_end_d3 <= line_end_d2;
            row_y_d1 <= row_y;
            row_y_d2 <= row_y_d1;
            row_y_d3 <= row_y_d2;

            for (n = 0; n < 4; n = n + 1) begin
                c1_valid[n] <= edge_pix && cand_valid[n] &&
                    (x_cnt >= cand_x0[n]) && (x_cnt <= cand_x1[n]) &&
                    (y_cnt >= cand_y0[n]) && (y_cnt <= cand_y1[n]);
                c1_x[n] <= x_cnt;
                c1_y[n] <= y_cnt;
                c1_dx[n] <= (x_cnt >= cand_cx[n]) ?
                            (x_cnt - cand_cx[n]) :
                            (cand_cx[n] - x_cnt);
                c1_dy[n] <= (y_cnt >= cand_cy[n]) ?
                            (y_cnt - cand_cy[n]) :
                            (cand_cy[n] - y_cnt);

                c2_valid[n] <= c1_valid[n];
                c2_x[n] <= c1_x[n];
                c2_y[n] <= c1_y[n];
                c2_d2[n] <= (c1_dx[n] * c1_dx[n]) +
                            (c1_dy[n] * c1_dy[n]);

                if (c2_valid[n]) begin
                    if (cand_edge_count[n] != 16'hFFFF)
                        cand_edge_count[n] <= cand_edge_count[n] + 1'b1;
                    if ((c2_d2[n] <
                         (cand_r2[n] - (cand_r2[n] >> 2))) ||
                        (c2_d2[n] >
                         (cand_r2[n] + (cand_r2[n] >> 1)))) begin
                        if (cand_bad_count[n] != 16'hFFFF)
                            cand_bad_count[n] <= cand_bad_count[n] + 1'b1;
                    end
                    if (cand_row_count[n] == 0) begin
                        cand_row_x0[n] <= c2_x[n];
                        cand_row_x1[n] <= c2_x[n];
                    end else begin
                        if (c2_x[n] < cand_row_x0[n])
                            cand_row_x0[n] <= c2_x[n];
                        if (c2_x[n] > cand_row_x1[n])
                            cand_row_x1[n] <= c2_x[n];
                    end
                    if (cand_row_count[n] != 12'hFFF)
                        cand_row_count[n] <= cand_row_count[n] + 1'b1;
                end
            end

            if (line_end_d3) begin
                for (n = 0; n < 4; n = n + 1) begin
                    if (cand_valid[n] && (cand_row_count[n] >= 2) &&
                        (row_y_d3 >= cand_y0[n]) &&
                        (row_y_d3 <= cand_y1[n]))
                        cand_span_sum[n] <= cand_span_sum[n] +
                            (cand_row_x1[n] - cand_row_x0[n] + 1'b1);
                    cand_row_count[n] <= 12'd0;
                end
            end

            if (vsync_fall) begin
                for (n = 0; n < 4; n = n + 1) begin
                    cand_edge_count[n] <= 16'd0;
                    cand_bad_count[n] <= 16'd0;
                    cand_span_sum[n] <= 32'd0;
                    cand_row_count[n] <= 12'd0;
                end
            end
        end
    end

    wire [3:0] rect_on;
    wire [3:0] circle_on;
    genvar gi;
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : gen_outline
            VIP_ShapeOutlinePixel u_outline (
                .clk        (clk),
                .rst_n      (rst_n),
                .x_cnt      (x_cnt),
                .y_cnt      (y_cnt),
                .valid      (draw_valid[gi]),
                .shape_type (draw_type[gi]),
                .x0         (draw_x0[gi]),
                .x1         (draw_x1[gi]),
                .y0         (draw_y0[gi]),
                .y1         (draw_y1[gi]),
                .rect_on    (rect_on[gi]),
                .circle_on  (circle_on[gi])
            );
        end
    endgenerate

    wire any_rect = |rect_on;
    wire any_circle = |circle_on;

    always @(*) begin
        if (circle_on != 4'd0)
            shape_type = 2'd2;
        else if (rect_on != 4'd0)
            shape_type = 2'd1;
        else if (draw_valid[0] && (draw_type[0] == 2'd2) ||
                 draw_valid[1] && (draw_type[1] == 2'd2) ||
                 draw_valid[2] && (draw_type[2] == 2'd2) ||
                 draw_valid[3] && (draw_type[3] == 2'd2))
            shape_type = 2'd2;
        else if (draw_valid[0] && (draw_type[0] == 2'd1) ||
                 draw_valid[1] && (draw_type[1] == 2'd1) ||
                 draw_valid[2] && (draw_type[2] == 2'd1) ||
                 draw_valid[3] && (draw_type[3] == 2'd1))
            shape_type = 2'd1;
        else
            shape_type = 2'd0;
    end

    reg [3:0] circle_count_calc;
    reg [3:0] rect_count_calc;
    always @(*) begin
        circle_count_calc = 4'd0;
        rect_count_calc = 4'd0;
        for (n = 0; n < 4; n = n + 1) begin
            if (draw_valid[n] && (draw_type[n] == 2'd2))
                circle_count_calc = circle_count_calc + 1'b1;
            else if (draw_valid[n] && (draw_type[n] == 2'd1))
                rect_count_calc = rect_count_calc + 1'b1;
        end
    end

    assign circle_count_out = circle_count_calc;
    assign rect_count_out = rect_count_calc;

    reg [7:0] d1_r, d1_g, d1_b, d2_r, d2_g, d2_b, d3_r, d3_g, d3_b;
    reg d1_vsync, d1_href, d1_hsync;
    reg d2_vsync, d2_href, d2_hsync;
    reg d3_vsync, d3_href, d3_hsync;
    reg [13:0] d1_x, d1_y, d2_x, d2_y, d3_x, d3_y;

    wire guide_on =
        (d3_x >= roi_x0 - 2) && (d3_x <= roi_x1 + 2) &&
        (d3_y >= roi_y0 - 2) && (d3_y <= roi_y1 + 2) &&
        ((d3_x < roi_x0 + 2) || (d3_x > roi_x1 - 2) ||
         (d3_y < roi_y0 + 2) || (d3_y > roi_y1 - 2));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d1_r <= 8'd0; d1_g <= 8'd0; d1_b <= 8'd0;
            d2_r <= 8'd0; d2_g <= 8'd0; d2_b <= 8'd0;
            d3_r <= 8'd0; d3_g <= 8'd0; d3_b <= 8'd0;
            d1_vsync <= 1'b0; d1_href <= 1'b0; d1_hsync <= 1'b0;
            d2_vsync <= 1'b0; d2_href <= 1'b0; d2_hsync <= 1'b0;
            d3_vsync <= 1'b0; d3_href <= 1'b0; d3_hsync <= 1'b0;
            d1_x <= 14'd0; d1_y <= 14'd0;
            d2_x <= 14'd0; d2_y <= 14'd0;
            d3_x <= 14'd0; d3_y <= 14'd0;
            post_frame_vsync <= 1'b0;
            post_frame_href <= 1'b0;
            post_frame_hsync <= 1'b0;
            post_img_red <= 8'd0;
            post_img_green <= 8'd0;
            post_img_blue <= 8'd0;
        end else begin
            d1_r <= per_img_red; d1_g <= per_img_green; d1_b <= per_img_blue;
            d2_r <= d1_r; d2_g <= d1_g; d2_b <= d1_b;
            d3_r <= d2_r; d3_g <= d2_g; d3_b <= d2_b;
            d1_vsync <= per_frame_vsync; d1_href <= per_frame_href;
            d1_hsync <= per_frame_hsync;
            d2_vsync <= d1_vsync; d2_href <= d1_href; d2_hsync <= d1_hsync;
            d3_vsync <= d2_vsync; d3_href <= d2_href; d3_hsync <= d2_hsync;
            d1_x <= x_cnt; d1_y <= y_cnt;
            d2_x <= d1_x; d2_y <= d1_y;
            d3_x <= d2_x; d3_y <= d2_y;

            post_frame_vsync <= d3_vsync;
            post_frame_href <= d3_href;
            post_frame_hsync <= d3_hsync;
            if (any_rect) begin
                post_img_red <= 8'hFF;
                post_img_green <= 8'hFF;
                post_img_blue <= 8'h00;
            end else if (any_circle) begin
                post_img_red <= 8'h00;
                post_img_green <= 8'hFF;
                post_img_blue <= 8'hFF;
            end else if (guide_on) begin
                post_img_red <= 8'h00;
                post_img_green <= 8'h40;
                post_img_blue <= 8'h40;
            end else begin
                post_img_red <= d3_r;
                post_img_green <= d3_g;
                post_img_blue <= d3_b;
            end
        end
    end
endmodule
