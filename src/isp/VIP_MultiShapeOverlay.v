`timescale 1ns/1ps

// Multi-object contour tracker for task 9.
//
// The old task-9 detector used one global bounding box over the whole frame.
// That cannot work when there are several objects or when the background has
// ordinary texture.  This module keeps per-object statistics instead:
//
//   1. threshold the confirmed Sobel edge map into a binary contour mask;
//   2. extract horizontal runs of contour pixels;
//   3. match each run with overlapping runs from the previous line;
//   4. update one independent object record for each connected contour;
//   5. classify each record as circle / rectangle;
//   6. draw a fitted ellipse or rectangle for every valid object on the next
//      frame, and show two counters in the top-left corner.
//
// The implementation is deliberately stream-oriented and needs no full-frame
// label memory.  The maximum object count is small, which matches the contest
// demo of a few separated geometric shapes.
module VIP_MultiShapeOverlay #(
    parameter [13:0] IMG_HDISP = 14'd1920,
    parameter [13:0] IMG_VDISP = 14'd1080,
    parameter [3:0]  MAX_OBJ   = 4'd8,
    parameter [4:0]  MAX_RUNS  = 5'd16,
    parameter [7:0]  EDGE_THRESHOLD = 8'd8,
    parameter        SHOW_BUILTIN_COUNTERS = 1'b0
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
    output reg  [1:0]   shape_type,
    output wire [3:0]   circle_count_out,
    output wire [3:0]   rect_count_out
    );

    localparam [1:0] ST_IDLE    = 2'd0;
    localparam [1:0] ST_PENDING = 2'd1;
    localparam [1:0] ST_COPY    = 2'd2;
    // At least 1/8 of a 1920x1080 display, using the object's bounding box.
    localparam [27:0] MIN_BOX_AREA = 28'd259200;
    localparam [13:0] MIN_SIDE     = 14'd300;

    reg [13:0] x_cnt;
    reg [13:0] y_cnt;
    reg        href_d;
    reg        vsync_d;
    wire       href_rise   = per_frame_href && !href_d;
    wire       vsync_rise  = per_frame_vsync && !vsync_d;
    wire       vsync_fall  = vsync_d && !per_frame_vsync;
    wire       line_end    = href_d && !per_frame_href;
    wire       pixel_valid = per_frame_href && per_frame_vsync;

    // -----------------------------------------------------------------
    // Line-run extraction
    // -----------------------------------------------------------------
    // Central target ROI.  The competition only needs a stable single
    // "specific shape"; restricting the tracker to the centre suppresses
    // background edges far away from the target.
    // Fixed central target window.  Keeping this much smaller than the full
    // screen prevents the frame border and distant background edges from
    // expanding the global contour to the whole display.
    wire in_frame = pixel_valid &&
                    (x_cnt >= 14'd480) && (x_cnt < 14'd1440) &&
                    (y_cnt >= 14'd270) && (y_cnt < 14'd810);
    // Use the already thresholded Sobel edge as the contour mask.  The
    // manual KEY1 threshold therefore controls background rejection directly;
    // the low-gradient fallback is intentionally not ORed in here, because on
    // a normal colour background it would create many false objects.
    wire mask_pixel = in_frame && per_img_edge;

    reg        run_active;
    reg [13:0] run_x0, run_x1;
    reg [13:0] pend_x0, pend_x1;
    reg        pend_valid;
    reg        copy_after_pending;
    reg [1:0]  run_state;
    reg [3:0]  match_label;

    reg [13:0] prev_x0 [0:MAX_RUNS-1];
    reg [13:0] prev_x1 [0:MAX_RUNS-1];
    reg [3:0]  prev_label [0:MAX_RUNS-1];
    reg [4:0]  prev_count;

    reg [13:0] cur_x0 [0:MAX_RUNS-1];
    reg [13:0] cur_x1 [0:MAX_RUNS-1];
    reg [3:0]  cur_label [0:MAX_RUNS-1];
    reg [4:0]  cur_count;

    // Frame-wide fallback statistics.  If the row-run tracker fails to form a
    // valid object, these still describe all visible contour pixels inside
    // the central ROI, so task 9 can draw a fallback bounding contour instead
    // of showing nothing.
    reg [13:0] g_min_x, g_max_x, g_min_y, g_max_y;
    reg [21:0] g_edge_count;
    reg [13:0] prev_box_x0, prev_box_x1, prev_box_y0, prev_box_y1;
    reg        prev_box_valid;
    reg [14:0] g_rad_min, g_rad_max;
    reg [21:0] g_rad_count;

    // -----------------------------------------------------------------
    // Per-object statistics
    // -----------------------------------------------------------------
    reg        obj_valid [0:MAX_OBJ-1];
    reg [13:0] obj_x0 [0:MAX_OBJ-1];
    reg [13:0] obj_x1 [0:MAX_OBJ-1];
    reg [13:0] obj_y0 [0:MAX_OBJ-1];
    reg [13:0] obj_y1 [0:MAX_OBJ-1];
    reg [21:0] obj_area [0:MAX_OBJ-1];
    reg [27:0] obj_box_area [0:MAX_OBJ-1];
    reg [3:0]  obj_alloc;

    // Snapshot used by the display side while the next frame is scanned.
    reg        final_valid [0:MAX_OBJ-1];
    reg [13:0] final_x0 [0:MAX_OBJ-1];
    reg [13:0] final_x1 [0:MAX_OBJ-1];
    reg [13:0] final_y0 [0:MAX_OBJ-1];
    reg [13:0] final_y1 [0:MAX_OBJ-1];
    reg [1:0]  final_type [0:MAX_OBJ-1];
    reg        final_area_ok [0:MAX_OBJ-1];
    reg [3:0]  circle_count;
    reg [3:0]  rect_count;

    integer    i;
    integer    k;

    // Match a current run against the previous line's run list.  The simple
    // nearest-overlap rule is sufficient because the requested objects are
    // separated and do not touch.
    function [3:0] match_prev_run;
        input [13:0] x0;
        input [13:0] x1;
        integer n;
        begin
            match_prev_run = 4'hF;
            for (n = 0; n < MAX_RUNS; n = n + 1) begin
                if ((n < prev_count) &&
                    (x0 <= prev_x1[n]) && (x1 >= prev_x0[n]))
                    match_prev_run = prev_label[n];
            end
        end
    endfunction

    function [1:0] classify_object;
        input        valid;
        input [13:0] x0;
        input [13:0] x1;
        input [13:0] y0;
        input [13:0] y1;
        input [21:0] area;
        reg [13:0]   w;
        reg [13:0]   h;
        reg [27:0]   box_area;
        reg          square_enough;
        begin
            w = x1 - x0 + 1'b1;
            h = y1 - y0 + 1'b1;
            box_area = w * h;
            square_enough = (w * 4 > h * 3) && (h * 4 > w * 3);

            if (!valid || (area < 12'd8) || (w < 5) || (h < 5))
                classify_object = 2'd0;
            else if (area * 8 > box_area * 7)
                classify_object = 2'd1;                 // solid rectangle
            else if (square_enough && (area * 8 > box_area * 5))
                classify_object = 2'd2;                 // solid circle
            else if (area * 4 > (w + h) * 7)
                classify_object = 2'd1;                 // outline rectangle
            else
                classify_object = 2'd2;                 // outline circle
        end
    endfunction

    // -----------------------------------------------------------------
    // Coordinate counters
    // -----------------------------------------------------------------
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

    wire [13:0] prev_cx = (prev_box_x0 + prev_box_x1) >> 1;
    wire [13:0] prev_cy = (prev_box_y0 + prev_box_y1) >> 1;
    wire        in_prev_box = prev_box_valid &&
                              (x_cnt >= prev_box_x0) && (x_cnt <= prev_box_x1) &&
                              (y_cnt >= prev_box_y0) && (y_cnt <= prev_box_y1);
    wire [13:0] prev_dx = (x_cnt >= prev_cx) ? (x_cnt - prev_cx) : (prev_cx - x_cnt);
    wire [13:0] prev_dy = (y_cnt >= prev_cy) ? (y_cnt - prev_cy) : (prev_cy - y_cnt);
    wire [14:0] prev_rad = {1'b0, prev_dx} + {1'b0, prev_dy};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            g_min_x <= 14'h3FFF;
            g_max_x <= 14'd0;
            g_min_y <= 14'h3FFF;
            g_max_y <= 14'd0;
            g_edge_count <= 22'd0;
            g_rad_min <= 15'h7FFF;
            g_rad_max <= 15'd0;
            g_rad_count <= 22'd0;
        end else if (vsync_rise) begin
            g_min_x <= 14'h3FFF;
            g_max_x <= 14'd0;
            g_min_y <= 14'h3FFF;
            g_max_y <= 14'd0;
            g_edge_count <= 22'd0;
            g_rad_min <= 15'h7FFF;
            g_rad_max <= 15'd0;
            g_rad_count <= 22'd0;
        end else if (mask_pixel) begin
            g_edge_count <= g_edge_count + 1'b1;
            if (x_cnt < g_min_x) g_min_x <= x_cnt;
            if (x_cnt > g_max_x) g_max_x <= x_cnt;
            if (y_cnt < g_min_y) g_min_y <= y_cnt;
            if (y_cnt > g_max_y) g_max_y <= y_cnt;
            if (in_prev_box) begin
                g_rad_count <= g_rad_count + 1'b1;
                if (prev_rad < g_rad_min) g_rad_min <= prev_rad;
                if (prev_rad > g_rad_max) g_rad_max <= prev_rad;
            end
        end
    end

    // -----------------------------------------------------------------
    // Run extraction and per-object update
    // -----------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            run_active <= 1'b0;
            run_x0 <= 14'd0;
            run_x1 <= 14'd0;
            pend_x0 <= 14'd0;
            pend_x1 <= 14'd0;
            pend_valid <= 1'b0;
            copy_after_pending <= 1'b0;
            run_state <= ST_IDLE;
            prev_count <= 5'd0;
            cur_count <= 5'd0;
            obj_alloc <= 4'd0;
            for (i = 0; i < MAX_RUNS; i = i + 1) begin
                prev_x0[i] <= 14'd0;
                prev_x1[i] <= 14'd0;
                prev_label[i] <= 4'hF;
                cur_x0[i] <= 14'd0;
                cur_x1[i] <= 14'd0;
                cur_label[i] <= 4'hF;
            end
            for (i = 0; i < MAX_OBJ; i = i + 1) begin
                obj_valid[i] <= 1'b0;
                obj_x0[i] <= 14'h3FFF;
                obj_x1[i] <= 14'd0;
                obj_y0[i] <= 14'h3FFF;
                obj_y1[i] <= 14'd0;
                obj_area[i] <= 22'd0;
                obj_box_area[i] <= 28'd0;
            end
        end else if (vsync_rise) begin
            // Start a new detection frame.
            run_active <= 1'b0;
            pend_valid <= 1'b0;
            copy_after_pending <= 1'b0;
            run_state <= ST_IDLE;
            prev_count <= 5'd0;
            cur_count <= 5'd0;
            obj_alloc <= 4'd0;
            for (i = 0; i < MAX_OBJ; i = i + 1) begin
                obj_valid[i] <= 1'b0;
                obj_x0[i] <= 14'h3FFF;
                obj_x1[i] <= 14'd0;
                obj_y0[i] <= 14'h3FFF;
                obj_y1[i] <= 14'd0;
                obj_area[i] <= 22'd0;
                obj_box_area[i] <= 28'd0;
            end
        end else begin
            case (run_state)
                ST_IDLE: begin
                    if (line_end) begin
                        if (run_active) begin
                            pend_x0 <= run_x0;
                            pend_x1 <= run_x1;
                            pend_valid <= 1'b1;
                            copy_after_pending <= 1'b1;
                            run_active <= 1'b0;
                            run_state <= ST_PENDING;
                        end else begin
                            run_state <= ST_COPY;
                        end
                    end else if (per_frame_href) begin
                        if (mask_pixel) begin
                            if (!run_active) begin
                                run_x0 <= x_cnt;
                                run_active <= 1'b1;
                            end
                            run_x1 <= x_cnt;
                        end else if (run_active) begin
                            pend_x0 <= run_x0;
                            pend_x1 <= run_x1;
                            pend_valid <= 1'b1;
                            copy_after_pending <= 1'b0;
                            run_active <= 1'b0;
                            run_state <= ST_PENDING;
                        end
                    end
                end

                ST_PENDING: begin
                    if (pend_valid) begin
                        match_label = match_prev_run(pend_x0, pend_x1);
                        if (match_label != 4'hF) begin
                            if (pend_x0 < obj_x0[match_label])
                                obj_x0[match_label] <= pend_x0;
                            if (pend_x1 > obj_x1[match_label])
                                obj_x1[match_label] <= pend_x1;
                            if (y_cnt < obj_y0[match_label])
                                obj_y0[match_label] <= y_cnt;
                            if (y_cnt > obj_y1[match_label])
                                obj_y1[match_label] <= y_cnt;
                            obj_area[match_label] <= obj_area[match_label] +
                                                     (pend_x1 - pend_x0 + 1'b1);
                        end else if (obj_alloc < MAX_OBJ) begin
                            obj_valid[obj_alloc] <= 1'b1;
                            obj_x0[obj_alloc] <= pend_x0;
                            obj_x1[obj_alloc] <= pend_x1;
                            obj_y0[obj_alloc] <= y_cnt;
                            obj_y1[obj_alloc] <= y_cnt;
                            obj_area[obj_alloc] <= (pend_x1 - pend_x0 + 1'b1);
                            obj_alloc <= obj_alloc + 1'b1;
                        end

                        if (cur_count < MAX_RUNS) begin
                            cur_x0[cur_count] <= pend_x0;
                            cur_x1[cur_count] <= pend_x1;
                            cur_label[cur_count] <=
                                (match_label != 4'hF) ? match_label :
                                ((obj_alloc < MAX_OBJ) ? obj_alloc : 4'hF);
                            cur_count <= cur_count + 1'b1;
                        end
                    end
                    pend_valid <= 1'b0;
                    run_state <= (copy_after_pending || line_end) ?
                                 ST_COPY : ST_IDLE;
                end

                ST_COPY: begin
                    for (i = 0; i < MAX_RUNS; i = i + 1) begin
                        prev_x0[i] <= cur_x0[i];
                        prev_x1[i] <= cur_x1[i];
                        prev_label[i] <= cur_label[i];
                    end
                    prev_count <= cur_count;
                    cur_count <= 5'd0;
                    copy_after_pending <= 1'b0;
                    run_state <= ST_IDLE;
                end
            endcase
        end
    end

    // -----------------------------------------------------------------
    // Frame-end classification.  Classification is pipelined over a small
    // state machine so the 14x14 bounding-box multiplier is not combined with
    // eight parallel object decisions in one clock.
    // -----------------------------------------------------------------
    reg        cls_active;
    reg [2:0]  cls_phase;
    reg [3:0]  cls_k;
    reg        cls_valid;
    reg [13:0] cls_x0, cls_x1, cls_y0, cls_y1;
    reg [13:0] cls_w, cls_h;
    reg [21:0] cls_area;
    reg [27:0] cls_box;
    reg [3:0]  cls_circle, cls_rect;
    reg [1:0]  cls_type;
    reg        sel_best_valid;
    reg [3:0]  sel_best_k;
    reg [1:0]  sel_best_type;
    reg [27:0] sel_best_area;
    reg [3:0]  sel_k;

    wire [13:0] g_w = g_max_x - g_min_x;
    wire [13:0] g_h = g_max_y - g_min_y;
    wire [14:0] g_sum = {1'b0, g_w} + {1'b0, g_h};
    wire [27:0] g_box_area = g_w * g_h;
    wire        g_valid = (g_min_x != 14'h3FFF) &&
                          (g_edge_count >= 22'd24) &&
                          (g_w >= MIN_SIDE) && (g_h >= MIN_SIDE) &&
                          (g_box_area >= MIN_BOX_AREA);
    wire        g_rad_valid = prev_box_valid && (g_rad_count >= 22'd20) &&
                              (g_rad_min > 15'd0) &&
                              (g_rad_max > g_rad_min);
    wire        g_rad_circle = g_rad_valid &&
                               (((g_rad_max - g_rad_min) * 2) < g_rad_min);
    wire [1:0]  g_type = g_rad_valid ?
                         (g_rad_circle ? 2'd2 : 2'd1) :
                         (((g_edge_count * 10) > (g_sum * 19)) ? 2'd1 : 2'd2);

    function [1:0] classify_registered;
        input        valid;
        input [13:0] w;
        input [13:0] h;
        input [21:0] area;
        input [27:0] box_area;
        reg          square_enough;
        begin
            square_enough = (w * 4 > h * 3) && (h * 4 > w * 3);
            if (!valid || (area < 12'd8) || (w < 5) || (h < 5))
                classify_registered = 2'd0;
            else if ((area << 3) > (box_area * 7))
                classify_registered = 2'd1;              // solid rectangle
            else if (square_enough && ((area << 3) > (box_area * 5)))
                classify_registered = 2'd2;              // solid circle
            else if ((area * 10) > ((w + h) * 19))
                classify_registered = 2'd1;              // outline rectangle
            else
                classify_registered = 2'd2;              // outline circle
        end
    endfunction

    wire cls_area_ok = (cls_box >= MIN_BOX_AREA) &&
                       (cls_w >= MIN_SIDE) &&
                       (cls_h >= MIN_SIDE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cls_active <= 1'b0;
            cls_phase  <= 3'd0;
            cls_k      <= 4'd0;
            cls_valid  <= 1'b0;
            cls_x0     <= 14'd0;
            cls_x1     <= 14'd0;
            cls_y0     <= 14'd0;
            cls_y1     <= 14'd0;
            cls_w      <= 14'd0;
            cls_h      <= 14'd0;
            cls_area   <= 22'd0;
            cls_box    <= 28'd0;
            cls_type   <= 2'd0;
            cls_circle <= 4'd0;
            cls_rect   <= 4'd0;
            sel_best_valid <= 1'b0;
            sel_best_k <= 4'd0;
            sel_best_type <= 2'd0;
            sel_best_area <= 28'd0;
            sel_k <= 4'd0;
            prev_box_x0 <= 14'd0;
            prev_box_x1 <= 14'd0;
            prev_box_y0 <= 14'd0;
            prev_box_y1 <= 14'd0;
            prev_box_valid <= 1'b0;
            circle_count <= 4'd0;
            rect_count   <= 4'd0;
            for (k = 0; k < MAX_OBJ; k = k + 1) begin
                final_valid[k] <= 1'b0;
                final_x0[k] <= 14'd0;
                final_x1[k] <= 14'd0;
                final_y0[k] <= 14'd0;
                final_y1[k] <= 14'd0;
                final_type[k] <= 2'd0;
                final_area_ok[k] <= 1'b0;
            end
        end else if (vsync_fall) begin
            cls_active <= 1'b1;
            cls_phase  <= 3'd0;
            cls_k      <= 4'd0;
            cls_circle <= 4'd0;
            cls_rect   <= 4'd0;
            circle_count <= 4'd0;
            rect_count   <= 4'd0;
            for (k = 0; k < MAX_OBJ; k = k + 1)
                final_valid[k] <= 1'b0;
        end else if (cls_active) begin
            case (cls_phase)
                3'd0: begin
                    if (cls_k < MAX_OBJ) begin
                        cls_valid <= obj_valid[cls_k];
                        cls_x0    <= obj_x0[cls_k];
                        cls_x1    <= obj_x1[cls_k];
                        cls_y0    <= obj_y0[cls_k];
                        cls_y1    <= obj_y1[cls_k];
                        cls_area  <= obj_area[cls_k];
                        cls_w     <= obj_x1[cls_k] - obj_x0[cls_k] + 1'b1;
                        cls_h     <= obj_y1[cls_k] - obj_y0[cls_k] + 1'b1;
                        cls_phase <= 3'd1;
                    end else begin
                        cls_phase <= 3'd3;
                    end
                end
                3'd1: begin
                    cls_box <= cls_w * cls_h;
                    cls_phase <= 3'd2;
                end
                3'd2: begin
                    cls_type = classify_registered(cls_valid, cls_w, cls_h,
                                                   cls_area, cls_box);
                    final_x0[cls_k] <= cls_x0;
                    final_x1[cls_k] <= cls_x1;
                    final_y0[cls_k] <= cls_y0;
                    final_y1[cls_k] <= cls_y1;
                    final_valid[cls_k] <= cls_valid;
                    final_type[cls_k] <= cls_type;
                    final_area_ok[cls_k] <= (cls_box >= MIN_BOX_AREA) &&
                                            (cls_w >= MIN_SIDE) &&
                                            (cls_h >= MIN_SIDE);
                    if(cls_valid && cls_area_ok) begin
                        if(cls_type == 2'd2 && circle_count < 4'd15)
                            circle_count <= circle_count + 1'b1;
                        else if(cls_type == 2'd1 && rect_count < 4'd15)
                            rect_count <= rect_count + 1'b1;
                    end
                    obj_box_area[cls_k] <= cls_box;
                    cls_k <= cls_k + 1'b1;
                    cls_phase <= 3'd0;
                end
                3'd3: begin
                    cls_active <= 1'b0;
                    cls_phase  <= 3'd0;
                end
                default: cls_phase <= 3'd0;
            endcase
        end
    end

    // LED/status type: circle has priority over rectangle when both exist.
    always @(*) begin
        if (circle_count != 4'd0)
            shape_type = 2'd2;
        else if (rect_count != 4'd0)
            shape_type = 2'd1;
        else
            shape_type = 2'd0;
    end

    assign circle_count_out = circle_count;
    assign rect_count_out   = rect_count;

    // -----------------------------------------------------------------
    // Multi-object outline drawing
    // -----------------------------------------------------------------
    wire [MAX_OBJ-1:0] rect_on;
    wire [MAX_OBJ-1:0] circle_on;

    genvar gi;
    generate
        for (gi = 0; gi < MAX_OBJ; gi = gi + 1) begin: gen_outline
            VIP_ShapeOutlinePixel u_outline (
                .clk        (clk),
                .rst_n      (rst_n),
                .x_cnt      (x_cnt),
                .y_cnt      (y_cnt),
                .valid      (final_valid[gi] && final_area_ok[gi]),
                .shape_type (final_type[gi]),
                .x0         (final_x0[gi]),
                .x1         (final_x1[gi]),
                .y0         (final_y0[gi]),
                .y1         (final_y1[gi]),
                .rect_on    (rect_on[gi]),
                .circle_on  (circle_on[gi])
            );
        end
    endgenerate

    wire any_rect   = |rect_on;
    wire any_circle = |circle_on;

    // -----------------------------------------------------------------
    // Small 5x7 text overlay: "C xN" and "R xM" in the top-left corner.
    // -----------------------------------------------------------------
    function [34:0] glyph_char;
        input [4:0] ch;
        begin
            case (ch)
                5'h00: glyph_char = 35'b11111_10001_10001_10001_10001_10001_11111;
                5'h01: glyph_char = 35'b00100_01100_00100_00100_00100_00100_01110;
                5'h02: glyph_char = 35'b11110_00001_00001_11110_10000_10000_11111;
                5'h03: glyph_char = 35'b11111_00001_00001_01111_00001_00001_11111;
                5'h04: glyph_char = 35'b10001_10001_10001_11111_00001_00001_00001;
                5'h05: glyph_char = 35'b11111_10000_10000_11111_00001_00001_11111;
                5'h06: glyph_char = 35'b01111_10000_10000_11111_10001_10001_11111;
                5'h07: glyph_char = 35'b11111_00001_00010_00100_01000_01000_01000;
                5'h08: glyph_char = 35'b11111_10001_10001_11111_10001_10001_11111;
                5'h09: glyph_char = 35'b11111_00001_00010_00100_01000_01000_01000; // '9' unused
                5'h0A: glyph_char = 35'b01111_10000_10000_10000_10000_10000_01111; // C
                5'h0B: glyph_char = 35'b11110_10001_10001_11110_10100_10010_10001; // R
                5'h0C: glyph_char = 35'b10001_01010_00100_00100_01010_10001_10001; // x
                5'h0D: glyph_char = 35'b11111_00100_00100_00100_00100_00100_11111; // I
                5'h0E: glyph_char = 35'b10000_10000_10000_10000_10000_10000_11111; // L
                5'h0F: glyph_char = 35'b11111_10000_10000_11110_10000_10000_11111; // E
                5'h10: glyph_char = 35'b11111_00100_00100_00100_00100_00100_00100; // T
                default: glyph_char = 35'd0;
            endcase
        end
    endfunction

    function glyph_pixel;
        input [4:0] ch;
        input [3:0] row;
        input [3:0] col;
        reg [34:0] bits;
        begin
            bits = glyph_char(ch);
            if ((row < 4'd7) && (col < 4'd5))
                glyph_pixel = bits[6'd34 -
                                   (({2'b00, row} * 6'd5) + {2'b00, col})];
            else
                glyph_pixel = 1'b0;
        end
    endfunction

    reg [3:0] text_line;
    reg [3:0] text_pos;
    reg [4:0] text_char;
    reg [3:0] text_col;
    reg [3:0] text_row;
    reg [13:0] text_xoff;
    reg       text_on;

    always @(*) begin
        text_on   = 1'b0;
        text_char = 5'h1F;
        text_line = 2'd3;
        text_pos  = 4'd0;
        text_col  = 4'd0;
        text_row  = 4'd0;
        text_xoff = 14'd0;

        if ((x_cnt >= 14'd64) && (x_cnt < 14'd280)) begin
            text_xoff = x_cnt - 14'd64;
            if ((y_cnt >= 14'd64) && (y_cnt < 14'd92))
                text_line = 2'd0;
            else if ((y_cnt >= 14'd112) && (y_cnt < 14'd140))
                text_line = 2'd1;

            if (text_line != 2'd3) begin
                text_pos  = (text_xoff < 14'd24) ? 4'd0 :
                            (text_xoff < 14'd48) ? 4'd1 :
                            (text_xoff < 14'd72) ? 4'd2 :
                            (text_xoff < 14'd96) ? 4'd3 :
                            (text_xoff < 14'd120) ? 4'd4 :
                            (text_xoff < 14'd144) ? 4'd5 :
                            (text_xoff < 14'd168) ? 4'd6 :
                            (text_xoff < 14'd192) ? 4'd7 : 4'd8;
                text_xoff = text_xoff - (text_pos * 14'd24);
                text_col  = text_xoff >> 2;
                text_row  = (text_line == 2'd0) ? ((y_cnt - 14'd64) >> 2) :
                                                   ((y_cnt - 14'd112) >> 2);

                if (text_line == 2'd0) begin
                    case (text_pos)
                        4'd0: text_char = 5'h0A;             // C
                        4'd1: text_char = 5'h0D;             // I
                        4'd2: text_char = 5'h0B;             // R
                        4'd3: text_char = 5'h0A;             // C
                        4'd4: text_char = 5'h0E;             // L
                        4'd5: text_char = 5'h0F;             // E
                        4'd6: text_char = 5'h1F;             // space
                        4'd7: text_char = 5'h0C;             // x
                        4'd8: text_char = {1'b0, circle_count}; // count
                        default: text_char = 5'h1F;
                    endcase
                end else begin
                    case (text_pos)
                        4'd0: text_char = 5'h0B;             // R
                        4'd1: text_char = 5'h0F;             // E
                        4'd2: text_char = 5'h0A;             // C
                        4'd3: text_char = 5'h10;             // T
                        4'd4: text_char = 5'h1F;             // space
                        4'd5: text_char = 5'h0C;             // x
                        4'd6: text_char = {1'b0, rect_count}; // count
                        default: text_char = 5'h1F;
                    endcase
                end

                if (SHOW_BUILTIN_COUNTERS &&
                    (text_col < 4'd5) && (text_row < 4'd7) &&
                    (text_char != 5'h1F) &&
                    glyph_pixel(text_char, text_row, text_col))
                    text_on = 1'b1;
            end
        end
    end

    // -----------------------------------------------------------------
    // Output pixel mixer
    // -----------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            post_frame_vsync <= 1'b0;
            post_frame_href  <= 1'b0;
            post_frame_hsync <= 1'b0;
            post_img_red     <= 8'd0;
            post_img_green   <= 8'd0;
            post_img_blue    <= 8'd0;
        end else begin
            post_frame_vsync <= per_frame_vsync;
            post_frame_href  <= per_frame_href;
            post_frame_hsync <= per_frame_hsync;

            if (text_on) begin
                post_img_red   <= 8'hFF;
                post_img_green <= 8'hFF;
                post_img_blue  <= 8'hFF;
            end else if (any_rect) begin
                post_img_red   <= 8'hFF;
                post_img_green <= 8'hFF;
                post_img_blue  <= 8'h00;
            end else if (any_circle) begin
                post_img_red   <= 8'h00;
                post_img_green <= 8'hFF;
                post_img_blue  <= 8'hFF;
            end else begin
                post_img_red   <= per_img_red;
                post_img_green <= per_img_green;
                post_img_blue  <= per_img_blue;
            end
        end
    end

endmodule


// One fitted outline pixel.  Rectangle objects use four straight sides.
// Circle objects use the average radius of the detected bounding box and a
// squared-distance band, so the result is an actual circular outline.
module VIP_ShapeOutlinePixel (
    input             clk,
    input             rst_n,
    input      [13:0] x_cnt,
    input      [13:0] y_cnt,
    input             valid,
    input      [1:0]  shape_type,
    input      [13:0] x0,
    input      [13:0] x1,
    input      [13:0] y0,
    input      [13:0] y1,
    output            rect_on,
    output            circle_on
    );

    // Three small pipeline stages keep the 14x14 distance multipliers out of
    // the same clock as the bounding-box and comparator logic.
    reg [13:0] s1_x, s1_y;
    reg [13:0] s1_x0, s1_x1, s1_y0, s1_y1;
    reg        s1_valid;
    reg [1:0]  s1_type;

    reg [13:0] s2_dx, s2_dy, s2_r;
    reg        s2_valid;
    reg [1:0]  s2_type;
    reg        s2_rect;

    reg        rect_on_r, circle_on_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_x <= 14'd0;
            s1_y <= 14'd0;
            s1_x0 <= 14'd0;
            s1_x1 <= 14'd0;
            s1_y0 <= 14'd0;
            s1_y1 <= 14'd0;
            s1_valid <= 1'b0;
            s1_type <= 2'd0;
            s2_dx <= 14'd0;
            s2_dy <= 14'd0;
            s2_r <= 14'd0;
            s2_valid <= 1'b0;
            s2_type <= 2'd0;
            s2_rect <= 1'b0;
            rect_on_r <= 1'b0;
            circle_on_r <= 1'b0;
        end else begin
            // Stage 1: align the current pixel and target box.
            s1_x     <= x_cnt;
            s1_y     <= y_cnt;
            s1_x0    <= x0;
            s1_x1    <= x1;
            s1_y0    <= y0;
            s1_y1    <= y1;
            s1_valid <= valid;
            s1_type  <= shape_type;

            // Stage 2: rectangle decision and circle centre/radius terms.
            s2_rect <=
                (s1_valid && (s1_type == 2'd1) &&
                 (s1_y >= s1_y0) && (s1_y <= s1_y1) &&
                 ((s1_x == s1_x0) || (s1_x == s1_x0 + 1'b1) ||
                  (s1_x == s1_x1) || (s1_x == s1_x1 - 1'b1))) ||
                (s1_valid && (s1_type == 2'd1) &&
                 (s1_x >= s1_x0) && (s1_x <= s1_x1) &&
                 ((s1_y == s1_y0) || (s1_y == s1_y0 + 1'b1) ||
                  (s1_y == s1_y1) || (s1_y == s1_y1 - 1'b1)));

            s2_dx <= (s1_x >= ((s1_x0 + s1_x1) >> 1)) ?
                     (s1_x - ((s1_x0 + s1_x1) >> 1)) :
                     (((s1_x0 + s1_x1) >> 1) - s1_x);
            s2_dy <= (s1_y >= ((s1_y0 + s1_y1) >> 1)) ?
                     (s1_y - ((s1_y0 + s1_y1) >> 1)) :
                     (((s1_y0 + s1_y1) >> 1) - s1_y);
            s2_r  <= (((s1_x1 - s1_x0) >> 1) +
                      ((s1_y1 - s1_y0) >> 1)) >> 1;
            s2_valid <= s1_valid;
            s2_type  <= s1_type;

            // Stage 3: squared-distance circle comparison.
            rect_on_r <= s2_rect;
            circle_on_r <= s2_valid && (s2_type == 2'd2) &&
                           (((s2_dx * s2_dx) + (s2_dy * s2_dy)) >=
                            (((s2_r * s2_r) > (s2_r * 4)) ?
                             ((s2_r * s2_r) - (s2_r * 4)) : 28'd0)) &&
                           (((s2_dx * s2_dx) + (s2_dy * s2_dy)) <=
                            ((s2_r * s2_r) + (s2_r * 4)));
        end
    end

    assign rect_on   = rect_on_r;
    assign circle_on = circle_on_r;

endmodule
