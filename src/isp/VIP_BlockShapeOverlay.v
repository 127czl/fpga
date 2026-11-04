`timescale 1ns/1ps

// Task 9: real connected-component recognition on a 320x180 mask.
//
// The old task 9 classified 32x32 occupancy cells, so a large hollow outline
// could be split into several cells while a background cell won the candidate
// slot.  This implementation stores a complete low-resolution mask, labels it
// with an 8-connected union-find pass, merges true component statistics and
// verifies the largest component before drawing an outline.
module VIP_BlockShapeOverlay #(
    parameter [13:0] IMG_HDISP = 14'd1920,
    parameter [13:0] IMG_VDISP = 14'd1080,
    parameter [13:0] ROI_X0 = 14'd320,
    parameter [13:0] ROI_X1 = 14'd1599,
    parameter [13:0] ROI_Y0 = 14'd180,
    parameter [13:0] ROI_Y1 = 14'd899,

    // Limits are in mask cells.  One cell equals 4x4 source pixels.
    parameter [15:0] MIN_COMPONENT = 16'd96,
    parameter [31:0] MIN_BOX_AREA = 32'd16200,
    parameter [31:0] MAX_BOX_AREA = 32'd50000,
    parameter [8:0]  MIN_SIDE = 9'd72,
    parameter [8:0]  MAX_SIDE = 9'd300,
    parameter [7:0]  BOUNDARY_GUARD = 8'd6
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

    localparam [9:0] GRID_W = 10'd320;
    localparam [9:0] GRID_H = 10'd180;
    localparam [7:0] MAX_LABEL_ID = 8'd63;
    localparam [7:0] LABEL_LIMIT = 8'd64;

    localparam [3:0]
        S_IDLE       = 4'd0,
        S_WAIT       = 4'd1,
        S_INIT       = 4'd2,
        S_SCAN_LOAD  = 4'd3,
        S_SCAN_WAIT  = 4'd4,
        S_SCAN_PROC  = 4'd5,
        S_RESOLVE    = 4'd6,
        S_AGG_ROOT   = 4'd7,
        S_AGG_LABEL  = 4'd8,
        S_AGG_EVAL   = 4'd9,
        S_VER_LOAD   = 4'd10,
        S_VER_WAIT   = 4'd11,
        S_VER_PROC   = 4'd12,
        S_VER_DRAIN  = 4'd13,
        S_FINAL      = 4'd14;

    // ---------------------------------------------------------------
    // Video timing and ROI counters
    // ---------------------------------------------------------------
    reg [13:0] x_cnt;
    reg [13:0] y_cnt;
    reg        href_d;
    reg        vsync_d;

    wire href_rise = per_frame_href && !href_d;
    wire vsync_rise = per_frame_vsync && !vsync_d;
    wire in_roi = per_frame_href && per_frame_vsync &&
                  (x_cnt >= ROI_X0) && (x_cnt <= ROI_X1) &&
                  (y_cnt >= ROI_Y0) && (y_cnt <= ROI_Y1);
    wire [9:0] cell_x = (x_cnt - ROI_X0) >> 2;
    wire [9:0] cell_y = (y_cnt - ROI_Y0) >> 2;
    wire [1:0] cell_x_lsb = (x_cnt - ROI_X0) & 2'b11;
    wire [1:0] cell_y_lsb = (y_cnt - ROI_Y0) & 2'b11;
    wire cell_done = in_roi && (cell_x_lsb == 2'b11) &&
                     (cell_y_lsb == 2'b11);
    wire capture_done = in_roi &&
                        (x_cnt == ROI_X1) && (y_cnt == ROI_Y1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_cnt <= 14'd0;
            y_cnt <= 14'd0;
            href_d <= 1'b0;
            vsync_d <= 1'b0;
        end else begin
            href_d <= per_frame_href;
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

    // ---------------------------------------------------------------
    // 4x4 mask capture.  A cell needs two edge pixels, which removes isolated
    // noise but keeps a projected 2-3 mm ink line.
    // ---------------------------------------------------------------
    reg [GRID_W-1:0] cell_hit_once;
    reg [GRID_W-1:0] cell_hit_twice;
    reg [GRID_W-1:0] capture_row;
    reg [GRID_W-1:0] capture_row_next;

    wire cell_edge_now = in_roi && per_img_edge;
    wire cell_mask_now = cell_hit_twice[cell_x] ||
                         (cell_hit_once[cell_x] && cell_edge_now);

    always @(*) begin
        capture_row_next = capture_row;
        capture_row_next[cell_x] = cell_mask_now;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            capture_row <= {GRID_W{1'b0}};
            cell_hit_once <= {GRID_W{1'b0}};
            cell_hit_twice <= {GRID_W{1'b0}};
        end else begin
            if (vsync_rise) begin
                capture_row <= {GRID_W{1'b0}};
                cell_hit_once <= {GRID_W{1'b0}};
                cell_hit_twice <= {GRID_W{1'b0}};
            end
            if (cell_edge_now) begin
                if (cell_hit_once[cell_x])
                    cell_hit_twice[cell_x] <= 1'b1;
                else
                    cell_hit_once[cell_x] <= 1'b1;
            end
            if (cell_done) begin
                capture_row <= capture_row_next;
                cell_hit_once[cell_x] <= 1'b0;
                cell_hit_twice[cell_x] <= 1'b0;
            end
        end
    end

    // A full mask row is 320 bits.  It is stored as sixteen 20-bit BRAM
    // words per row so Efinity uses RAM10 instead of 57.6K logic-memory bits.
    wire mask_we = cell_done && (cell_x == GRID_W - 1'b1);
    wire [8:0] mask_waddr = {1'b0, cell_y[7:0]};
    wire [8:0] mask_raddr = (work_state >= S_VER_LOAD) ?
                            {1'b0, verify_y[7:0]} :
                            {1'b0, scan_y[7:0]};
    wire [GRID_W-1:0] mask_rdata;

    genvar gi;
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : gen_mask_ram
            EFX_RAM10 #(
                .READ_WIDTH(20),
                .WRITE_WIDTH(20),
                .OUTPUT_REG(1'b0),
                .WRITE_MODE("READ_FIRST")
            ) u_mask_ram (
                .WCLK(clk),
                .WE(2'b11),
                .WCLKE(mask_we),
                .WADDREN(1'b1),
                .WDATA(capture_row_next[gi*20 +: 20]),
                .WADDR(mask_waddr),
                .RCLK(clk),
                .RE(1'b1),
                .RST(1'b0),
                .RADDREN(1'b1),
                .RDATA(mask_rdata[gi*20 +: 20]),
                .RADDR(mask_raddr)
            );
        end
    endgenerate

    // ---------------------------------------------------------------
    // Connected-component records
    // ---------------------------------------------------------------
    reg [7:0]  ccl_parent [0:LABEL_LIMIT-1];
    reg [7:0]  root_map [0:LABEL_LIMIT-1];
    reg [15:0] lab_area [0:LABEL_LIMIT-1];
    reg [8:0]  lab_x0 [0:LABEL_LIMIT-1];
    reg [8:0]  lab_x1 [0:LABEL_LIMIT-1];
    reg [8:0]  lab_y0 [0:LABEL_LIMIT-1];
    reg [8:0]  lab_y1 [0:LABEL_LIMIT-1];
    reg [8:0]  lab_run_h [0:LABEL_LIMIT-1];
    reg [8:0]  lab_run_v [0:LABEL_LIMIT-1];
    reg [8:0]  lab_max_h [0:LABEL_LIMIT-1];
    reg [8:0]  lab_max_v [0:LABEL_LIMIT-1];

    reg [7:0]  label_bank0 [0:GRID_W-1];
    reg [7:0]  label_bank1 [0:GRID_W-1];
    reg [GRID_W-1:0] prev_mask_row;
    reg [GRID_W-1:0] scan_row_q;
    reg [7:0]  label_count;

    reg [3:0] work_state;
    reg [2:0] wait_cnt;
    reg [7:0] init_idx;
    reg [9:0] scan_x;
    reg [9:0] scan_y;
    reg [2:0] resolve_pass;
    reg [7:0] resolve_idx;

    reg [7:0]  agg_root;
    reg [7:0]  agg_label;
    reg [15:0] agg_area;
    reg [8:0]  agg_x0, agg_x1, agg_y0, agg_y1;
    reg [8:0]  agg_max_h, agg_max_v;

    reg        best_valid;
    reg [7:0]  best_root;
    reg [8:0]  best_x0, best_x1, best_y0, best_y1;
    reg [8:0]  best_max_h, best_max_v;
    reg [15:0] best_area;

    // Verification pass
    reg [7:0]  verify_count;
    reg [9:0]  verify_x, verify_y;
    reg [GRID_W-1:0] verify_prev_mask;
    reg [GRID_W-1:0] verify_row_q;
    reg [2:0]  verify_drain;
    reg [15:0] verify_area;
    reg [15:0] verify_rad_good;
    reg [3:0]  verify_corners;

    reg signed [9:0] verify_min_d;
    reg signed [9:0] verify_max_d;
    reg [8:0]  verify_min_s;
    reg [8:0]  verify_max_s;
    reg [8:0]  verify_min_s_x, verify_min_s_y;
    reg [8:0]  verify_max_s_x, verify_max_s_y;
    reg [8:0]  verify_min_d_x, verify_min_d_y;
    reg [8:0]  verify_max_d_x, verify_max_d_y;

    reg [9:0]  v1_dx, v1_dy;
    reg        v1_left, v1_top;
    reg        v1_valid;
    reg        v2_valid;
    reg [19:0] v2_rad2;
    reg        v3_valid;
    reg [19:0] v3_rad2;

    // Consecutive-frame confirmation suppresses one-frame false candidates.
    reg        pending_valid;
    reg [1:0]  pending_count;
    reg [1:0]  miss_count;
    reg [8:0]  pending_x0, pending_x1, pending_y0, pending_y1;

    // Fitted geometry in full-resolution coordinates
    reg        box_valid;
    reg [1:0]  box_type;
    reg [13:0] circle_x0, circle_x1, circle_y0, circle_y1;
    reg [13:0] circle_r;
    reg [13:0] rect_p0_x, rect_p0_y;
    reg [13:0] rect_p1_x, rect_p1_y;
    reg [13:0] rect_p2_x, rect_p2_y;
    reg [13:0] rect_p3_x, rect_p3_y;

    wire scan_mask_bit = scan_row_q[scan_x];
    wire [7:0] scan_w_label =
        (scan_x != 0) ?
        (scan_y[0] ? label_bank1[scan_x - 1'b1] :
                     label_bank0[scan_x - 1'b1]) : 8'd0;
    wire [7:0] scan_nw_label =
        (scan_x != 0 && prev_mask_row[scan_x - 1'b1]) ?
        (scan_y[0] ? label_bank0[scan_x - 1'b1] :
                     label_bank1[scan_x - 1'b1]) : 8'd0;
    wire [7:0] scan_n_label =
        prev_mask_row[scan_x] ?
        (scan_y[0] ? label_bank0[scan_x] : label_bank1[scan_x]) : 8'd0;
    wire [7:0] scan_ne_label =
        (scan_x != GRID_W - 1'b1 && prev_mask_row[scan_x + 1'b1]) ?
        (scan_y[0] ? label_bank0[scan_x + 1'b1] :
                     label_bank1[scan_x + 1'b1]) : 8'd0;

    function [7:0] min_nonzero4;
        input [7:0] a;
        input [7:0] b;
        input [7:0] c;
        input [7:0] d;
        reg [7:0] m;
        begin
            m = 8'd0;
            if (a != 0) m = a;
            if (b != 0 && (m == 0 || b < m)) m = b;
            if (c != 0 && (m == 0 || c < m)) m = c;
            if (d != 0 && (m == 0 || d < m)) m = d;
            min_nonzero4 = m;
        end
    endfunction

    wire [7:0] scan_neighbor = min_nonzero4(scan_w_label, scan_nw_label,
                                             scan_n_label, scan_ne_label);
    reg [7:0] scan_assigned;
    always @(*) begin
        scan_assigned = 8'd0;
        if (scan_mask_bit) begin
            if (scan_neighbor != 0)
                scan_assigned = scan_neighbor;
            else if (label_count <= MAX_LABEL_ID)
                scan_assigned = label_count;
        end
    end

    wire [8:0] scan_h_next =
        (scan_x == 0 || !scan_row_q[scan_x - 1'b1]) ? 9'd1 :
        (lab_run_h[scan_assigned] + 1'b1);
    wire [8:0] scan_v_next =
        !prev_mask_row[scan_x] ? 9'd1 :
        (lab_run_v[scan_assigned] + 1'b1);

    wire [7:0] verify_w_label =
        (verify_x != 0) ?
        (verify_y[0] ? label_bank1[verify_x - 1'b1] :
                       label_bank0[verify_x - 1'b1]) : 8'd0;
    wire [7:0] verify_nw_label =
        (verify_x != 0 && verify_prev_mask[verify_x - 1'b1]) ?
        (verify_y[0] ? label_bank0[verify_x - 1'b1] :
                       label_bank1[verify_x - 1'b1]) : 8'd0;
    wire [7:0] verify_n_label =
        verify_prev_mask[verify_x] ?
        (verify_y[0] ? label_bank0[verify_x] :
                       label_bank1[verify_x]) : 8'd0;
    wire [7:0] verify_ne_label =
        (verify_x != GRID_W - 1'b1 &&
         verify_prev_mask[verify_x + 1'b1]) ?
        (verify_y[0] ? label_bank0[verify_x + 1'b1] :
                       label_bank1[verify_x + 1'b1]) : 8'd0;
    wire [7:0] verify_neighbor = min_nonzero4(verify_w_label,
                                               verify_nw_label,
                                               verify_n_label,
                                               verify_ne_label);
    wire verify_mask_bit = verify_row_q[verify_x];
    reg [7:0] verify_assigned;
    always @(*) begin
        verify_assigned = 8'd0;
        if (verify_mask_bit) begin
            if (verify_neighbor != 0)
                verify_assigned = verify_neighbor;
            else if (verify_count <= MAX_LABEL_ID)
                verify_assigned = verify_count;
        end
    end

    wire [9:0] verify_center_x = best_x0 + best_x1;
    wire [9:0] verify_center_y = best_y0 + best_y1;
    wire [8:0] verify_half_w =
        ((best_x1 - best_x0) + 1'b1) >> 1;
    wire [8:0] verify_half_h =
        ((best_y1 - best_y0) + 1'b1) >> 1;
    wire [10:0] verify_cell_x2 = {verify_x, 1'b0};
    wire [10:0] verify_cell_y2 = {verify_y, 1'b0};
    wire [10:0] verify_abs_dx =
        (verify_cell_x2 >= verify_center_x) ?
        (verify_cell_x2 - verify_center_x) :
        (verify_center_x - verify_cell_x2);
    wire [10:0] verify_abs_dy =
        (verify_cell_y2 >= verify_center_y) ?
        (verify_cell_y2 - verify_center_y) :
        (verify_center_y - verify_cell_y2);
    wire [8:0] verify_sum_xy = verify_x + verify_y;
    wire signed [9:0] verify_diff_xy =
        $signed({1'b0, verify_x}) - $signed({1'b0, verify_y});
    wire verify_is_best =
        verify_mask_bit && (verify_assigned != 0) &&
        (root_map[verify_assigned] == best_root);
    wire [8:0] verify_radius_ref =
        (verify_half_w + verify_half_h) >> 1;
    wire [17:0] verify_radius_ref2 =
        verify_radius_ref * verify_radius_ref;

    function [7:0] find_root;
        input [7:0] start;
        integer k;
        reg [7:0] r;
        begin
            r = start;
            for (k = 0; k < 8; k = k + 1)
                r = ccl_parent[r];
            find_root = r;
        end
    endfunction

    function [8:0] abs_diff9;
        input [8:0] a;
        input [8:0] b;
        begin
            abs_diff9 = (a >= b) ? (a - b) : (b - a);
        end
    endfunction

    // ---------------------------------------------------------------
    // Main frame sequencer.  Work begins after the bottom-right ROI cell and
    // has almost three milliseconds before the next frame starts.
    // ---------------------------------------------------------------
    integer si;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            work_state <= S_IDLE;
            wait_cnt <= 3'd0;
            init_idx <= 8'd0;
            scan_x <= 10'd0;
            scan_y <= 10'd0;
            prev_mask_row <= {GRID_W{1'b0}};
            scan_row_q <= {GRID_W{1'b0}};
            label_count <= 8'd1;
            resolve_pass <= 3'd0;
            resolve_idx <= 8'd1;
            agg_root <= 8'd1;
            agg_label <= 8'd1;
            agg_area <= 16'd0;
            agg_x0 <= 9'd0;
            agg_x1 <= 9'd0;
            agg_y0 <= 9'd0;
            agg_y1 <= 9'd0;
            agg_max_h <= 9'd0;
            agg_max_v <= 9'd0;
            best_valid <= 1'b0;
            best_root <= 8'd0;
            best_x0 <= 9'd0;
            best_x1 <= 9'd0;
            best_y0 <= 9'd0;
            best_y1 <= 9'd0;
            best_max_h <= 9'd0;
            best_max_v <= 9'd0;
            best_area <= 16'd0;
            verify_count <= 8'd1;
            verify_x <= 10'd0;
            verify_y <= 10'd0;
            verify_prev_mask <= {GRID_W{1'b0}};
            verify_row_q <= {GRID_W{1'b0}};
            verify_drain <= 3'd0;
            verify_area <= 16'd0;
            verify_rad_good <= 16'd0;
            verify_corners <= 4'd0;
            verify_min_s <= 9'h1FF;
            verify_max_s <= 9'd0;
            verify_min_d <= 10'sd511;
            verify_max_d <= -10'sd512;
            verify_min_s_x <= 9'd0;
            verify_min_s_y <= 9'd0;
            verify_max_s_x <= 9'd0;
            verify_max_s_y <= 9'd0;
            verify_min_d_x <= 9'd0;
            verify_min_d_y <= 9'd0;
            verify_max_d_x <= 9'd0;
            verify_max_d_y <= 9'd0;
            v1_valid <= 1'b0;
            v2_valid <= 1'b0;
            v3_valid <= 1'b0;
            v1_dx <= 10'd0;
            v1_dy <= 10'd0;
            v1_left <= 1'b0;
            v1_top <= 1'b0;
            v2_rad2 <= 20'd0;
            v3_rad2 <= 20'd0;
            pending_valid <= 1'b0;
            pending_count <= 2'd0;
            miss_count <= 2'd0;
            pending_x0 <= 9'd0;
            pending_x1 <= 9'd0;
            pending_y0 <= 9'd0;
            pending_y1 <= 9'd0;
            box_valid <= 1'b0;
            box_type <= 2'd0;
            circle_x0 <= 14'd0;
            circle_x1 <= 14'd0;
            circle_y0 <= 14'd0;
            circle_y1 <= 14'd0;
            circle_r <= 14'd0;
            rect_p0_x <= 14'd0;
            rect_p0_y <= 14'd0;
            rect_p1_x <= 14'd0;
            rect_p1_y <= 14'd0;
            rect_p2_x <= 14'd0;
            rect_p2_y <= 14'd0;
            rect_p3_x <= 14'd0;
            rect_p3_y <= 14'd0;
            for (si = 0; si < LABEL_LIMIT; si = si + 1) begin
                ccl_parent[si] <= si[7:0];
                root_map[si] <= si[7:0];
                lab_area[si] <= 16'd0;
                lab_x0[si] <= 9'd0;
                lab_x1[si] <= 9'd0;
                lab_y0[si] <= 9'd0;
                lab_y1[si] <= 9'd0;
                lab_run_h[si] <= 9'd0;
                lab_run_v[si] <= 9'd0;
                lab_max_h[si] <= 9'd0;
                lab_max_v[si] <= 9'd0;
            end
        end else begin
            // Radial and corner verification pipeline.
            v1_valid <= 1'b0;
            if (v1_valid) begin
                v2_valid <= 1'b1;
                v2_rad2 <= (v1_dx * v1_dx) + (v1_dy * v1_dy);
                if ((v1_dx * 4) > (verify_half_w * 3) &&
                    (v1_dy * 4) > (verify_half_h * 3)) begin
                    if (!v1_left && !v1_top) verify_corners[0] <= 1'b1;
                    if (v1_left && !v1_top)  verify_corners[1] <= 1'b1;
                    if (v1_left && v1_top)   verify_corners[2] <= 1'b1;
                    if (!v1_left && v1_top)  verify_corners[3] <= 1'b1;
                end
            end else
                v2_valid <= 1'b0;

            v3_valid <= v2_valid;
            if (v2_valid)
                v3_rad2 <= v2_rad2;
            if (v3_valid) begin
                if ((v3_rad2 * 100) >= (verify_radius_ref2 * 72) &&
                    (v3_rad2 * 100) <= (verify_radius_ref2 * 132))
                    verify_rad_good <= verify_rad_good + 1'b1;
            end

            if (capture_done && (work_state == S_IDLE)) begin
                work_state <= S_WAIT;
                wait_cnt <= 3'd0;
            end

            case (work_state)
                S_IDLE:
                    wait_cnt <= 3'd0;

                S_WAIT: begin
                    if (wait_cnt == 3'd3) begin
                        init_idx <= 8'd0;
                        work_state <= S_INIT;
                    end else
                        wait_cnt <= wait_cnt + 1'b1;
                end

                S_INIT: begin
                    ccl_parent[init_idx] <= init_idx;
                    root_map[init_idx] <= init_idx;
                    lab_area[init_idx] <= 16'd0;
                    lab_x0[init_idx] <= 9'd0;
                    lab_x1[init_idx] <= 9'd0;
                    lab_y0[init_idx] <= 9'd0;
                    lab_y1[init_idx] <= 9'd0;
                    lab_run_h[init_idx] <= 9'd0;
                    lab_run_v[init_idx] <= 9'd0;
                    lab_max_h[init_idx] <= 9'd0;
                    lab_max_v[init_idx] <= 9'd0;
                    if (init_idx == LABEL_LIMIT - 1'b1) begin
                        label_count <= 8'd1;
                        scan_x <= 10'd0;
                        scan_y <= 10'd0;
                        prev_mask_row <= {GRID_W{1'b0}};
                        work_state <= S_SCAN_LOAD;
                    end else
                        init_idx <= init_idx + 1'b1;
                end

                S_SCAN_LOAD: begin
                    work_state <= S_SCAN_WAIT;
                end

                S_SCAN_WAIT: begin
                    scan_row_q <= mask_rdata;
                    scan_x <= 10'd0;
                    work_state <= S_SCAN_PROC;
                end

                S_SCAN_PROC: begin
                    if (scan_mask_bit && (scan_assigned != 0)) begin
                        if (scan_w_label != 0 &&
                            scan_w_label != scan_assigned)
                            ccl_parent[scan_w_label] <= scan_assigned;
                        if (scan_nw_label != 0 &&
                            scan_nw_label != scan_assigned)
                            ccl_parent[scan_nw_label] <= scan_assigned;
                        if (scan_n_label != 0 &&
                            scan_n_label != scan_assigned)
                            ccl_parent[scan_n_label] <= scan_assigned;
                        if (scan_ne_label != 0 &&
                            scan_ne_label != scan_assigned)
                            ccl_parent[scan_ne_label] <= scan_assigned;

                        if (lab_area[scan_assigned] == 0) begin
                            lab_x0[scan_assigned] <= scan_x;
                            lab_x1[scan_assigned] <= scan_x;
                            lab_y0[scan_assigned] <= scan_y;
                            lab_y1[scan_assigned] <= scan_y;
                        end else begin
                            if (scan_x < lab_x0[scan_assigned])
                                lab_x0[scan_assigned] <= scan_x;
                            if (scan_x > lab_x1[scan_assigned])
                                lab_x1[scan_assigned] <= scan_x;
                            if (scan_y < lab_y0[scan_assigned])
                                lab_y0[scan_assigned] <= scan_y;
                            if (scan_y > lab_y1[scan_assigned])
                                lab_y1[scan_assigned] <= scan_y;
                        end
                        lab_area[scan_assigned] <=
                            lab_area[scan_assigned] + 1'b1;
                        lab_run_h[scan_assigned] <= scan_h_next;
                        lab_run_v[scan_assigned] <= scan_v_next;
                        if (scan_h_next > lab_max_h[scan_assigned])
                            lab_max_h[scan_assigned] <= scan_h_next;
                        if (scan_v_next > lab_max_v[scan_assigned])
                            lab_max_v[scan_assigned] <= scan_v_next;
                        if (scan_neighbor == 0 &&
                            label_count <= MAX_LABEL_ID)
                            label_count <= label_count + 1'b1;
                    end

                    if (scan_y[0])
                        label_bank1[scan_x] <= scan_assigned;
                    else
                        label_bank0[scan_x] <= scan_assigned;

                    if (scan_x == GRID_W - 1'b1) begin
                        prev_mask_row <= scan_row_q;
                        scan_x <= 10'd0;
                        if (scan_y == GRID_H - 1'b1) begin
                            resolve_idx <= 8'd1;
                            resolve_pass <= 3'd0;
                            work_state <= S_RESOLVE;
                        end else begin
                            scan_y <= scan_y + 1'b1;
                            work_state <= S_SCAN_LOAD;
                        end
                    end else
                        scan_x <= scan_x + 1'b1;
                end

                S_RESOLVE: begin
                    if (resolve_pass == 0)
                        root_map[resolve_idx] <= ccl_parent[resolve_idx];
                    else
                        root_map[resolve_idx] <=
                            root_map[root_map[resolve_idx]];

                    if (resolve_idx >= label_count) begin
                        resolve_idx <= 8'd1;
                        if (resolve_pass == 3'd6) begin
                            agg_root <= 8'd1;
                            agg_label <= 8'd1;
                            agg_area <= 16'd0;
                            agg_x0 <= 9'h1FF;
                            agg_x1 <= 9'd0;
                            agg_y0 <= 9'h1FF;
                            agg_y1 <= 9'd0;
                            agg_max_h <= 9'd0;
                            agg_max_v <= 9'd0;
                            best_valid <= 1'b0;
                            best_area <= 16'd0;
                            work_state <= S_AGG_ROOT;
                        end else begin
                            resolve_pass <= resolve_pass + 1'b1;
                            work_state <= S_RESOLVE;
                        end
                    end else
                        resolve_idx <= resolve_idx + 1'b1;
                end

                S_AGG_ROOT: begin
                    agg_label <= 8'd1;
                    agg_area <= 16'd0;
                    agg_x0 <= 9'h1FF;
                    agg_x1 <= 9'd0;
                    agg_y0 <= 9'h1FF;
                    agg_y1 <= 9'd0;
                    agg_max_h <= 9'd0;
                    agg_max_v <= 9'd0;
                    work_state <= S_AGG_LABEL;
                end

                S_AGG_LABEL: begin
                    if (root_map[agg_label] == agg_root) begin
                        agg_area <= agg_area + lab_area[agg_label];
                        if (lab_area[agg_label] != 0) begin
                            if (lab_x0[agg_label] < agg_x0)
                                agg_x0 <= lab_x0[agg_label];
                            if (lab_x1[agg_label] > agg_x1)
                                agg_x1 <= lab_x1[agg_label];
                            if (lab_y0[agg_label] < agg_y0)
                                agg_y0 <= lab_y0[agg_label];
                            if (lab_y1[agg_label] > agg_y1)
                                agg_y1 <= lab_y1[agg_label];
                        end
                        if (lab_max_h[agg_label] > agg_max_h)
                            agg_max_h <= lab_max_h[agg_label];
                        if (lab_max_v[agg_label] > agg_max_v)
                            agg_max_v <= lab_max_v[agg_label];
                    end
                    if (agg_label >= label_count)
                        work_state <= S_AGG_EVAL;
                    else
                        agg_label <= agg_label + 1'b1;
                end

                S_AGG_EVAL: begin
                    begin : agg_check
                        reg [8:0] w;
                        reg [8:0] h;
                        reg [31:0] box_area;
                        reg cand_ok;
                        w = (agg_x1 >= agg_x0) ? (agg_x1 - agg_x0 + 1'b1) :
                                                 9'd0;
                        h = (agg_y1 >= agg_y0) ? (agg_y1 - agg_y0 + 1'b1) :
                                                 9'd0;
                        box_area = w * h;
                        cand_ok = (root_map[agg_root] == agg_root) &&
                                  (agg_area >= MIN_COMPONENT) &&
                                  (w >= MIN_SIDE) && (h >= MIN_SIDE) &&
                                  (w <= MAX_SIDE) && (h <= MAX_SIDE) &&
                                  (box_area >= MIN_BOX_AREA) &&
                                  (box_area <= MAX_BOX_AREA) &&
                                  (agg_x0 > BOUNDARY_GUARD) &&
                                  (agg_y0 > BOUNDARY_GUARD) &&
                                  (agg_x1 < GRID_W - 1 - BOUNDARY_GUARD) &&
                                  (agg_y1 < GRID_H - 1 - BOUNDARY_GUARD) &&
                                  ({16'd0, agg_area} * 4 <= box_area * 3);
                        if (cand_ok && (agg_area > best_area)) begin
                            best_valid <= 1'b1;
                            best_root <= agg_root;
                            best_x0 <= agg_x0;
                            best_x1 <= agg_x1;
                            best_y0 <= agg_y0;
                            best_y1 <= agg_y1;
                            best_max_h <= agg_max_h;
                            best_max_v <= agg_max_v;
                            best_area <= agg_area;
                        end
                    end

                    if (agg_root >= label_count) begin
                        verify_count <= 8'd1;
                        verify_x <= 10'd0;
                        verify_y <= 10'd0;
                        verify_prev_mask <= {GRID_W{1'b0}};
                        verify_area <= 16'd0;
                        verify_rad_good <= 16'd0;
                        verify_corners <= 4'd0;
                        verify_min_s <= 9'h1FF;
                        verify_max_s <= 9'd0;
                        verify_min_d <= 10'sd511;
                        verify_max_d <= -10'sd512;
                        v1_valid <= 1'b0;
                        v2_valid <= 1'b0;
                        v3_valid <= 1'b0;
                        work_state <= S_VER_LOAD;
                    end else begin
                        agg_root <= agg_root + 1'b1;
                        work_state <= S_AGG_ROOT;
                    end
                end

                S_VER_LOAD: begin
                    work_state <= S_VER_WAIT;
                end

                S_VER_WAIT: begin
                    verify_row_q <= mask_rdata;
                    verify_x <= 10'd0;
                    work_state <= S_VER_PROC;
                end

                S_VER_PROC: begin
                    if (verify_is_best) begin
                        verify_area <= verify_area + 1'b1;
                        v1_valid <= 1'b1;
                        v1_dx <= verify_abs_dx;
                        v1_dy <= verify_abs_dy;
                        v1_left <= (verify_cell_x2 < verify_center_x);
                        v1_top <= (verify_cell_y2 < verify_center_y);

                        if (verify_sum_xy < verify_min_s) begin
                            verify_min_s <= verify_sum_xy;
                            verify_min_s_x <= verify_x;
                            verify_min_s_y <= verify_y;
                        end
                        if (verify_sum_xy > verify_max_s) begin
                            verify_max_s <= verify_sum_xy;
                            verify_max_s_x <= verify_x;
                            verify_max_s_y <= verify_y;
                        end
                        if (verify_diff_xy < verify_min_d) begin
                            verify_min_d <= verify_diff_xy;
                            verify_min_d_x <= verify_x;
                            verify_min_d_y <= verify_y;
                        end
                        if (verify_diff_xy > verify_max_d) begin
                            verify_max_d <= verify_diff_xy;
                            verify_max_d_x <= verify_x;
                            verify_max_d_y <= verify_y;
                        end
                    end

                    if (verify_y[0])
                        label_bank1[verify_x] <= verify_assigned;
                    else
                        label_bank0[verify_x] <= verify_assigned;

                    if (verify_x == GRID_W - 1'b1) begin
                        verify_prev_mask <= verify_row_q;
                        verify_x <= 10'd0;
                        if (verify_y == GRID_H - 1'b1) begin
                            verify_drain <= 3'd0;
                            work_state <= S_VER_DRAIN;
                        end else begin
                            verify_y <= verify_y + 1'b1;
                            work_state <= S_VER_LOAD;
                        end
                    end else
                        verify_x <= verify_x + 1'b1;
                end

                S_VER_DRAIN: begin
                    if (verify_drain == 3'd5)
                        work_state <= S_FINAL;
                    else
                        verify_drain <= verify_drain + 1'b1;
                end

                S_FINAL: begin
                    begin : final_check
                        reg [8:0] w;
                        reg [8:0] h;
                        reg aspect_ok;
                        reg circle_ok;
                        reg rect_ok;
                        reg candidate_ok;
                        reg [1:0] candidate_type;
                        w = best_x1 - best_x0 + 1'b1;
                        h = best_y1 - best_y0 + 1'b1;
                        aspect_ok = (w * 4 >= h * 3) &&
                                    (h * 4 >= w * 3);
                        circle_ok = (verify_area >= MIN_COMPONENT) &&
                                    aspect_ok &&
                                    (verify_rad_good * 100 >=
                                     verify_area * 70);
                        rect_ok = (verify_area >= MIN_COMPONENT) &&
                                  (verify_corners == 4'b1111);
                        candidate_ok = best_valid && (rect_ok || circle_ok);
                        candidate_type = rect_ok ? 2'd1 :
                                         circle_ok ? 2'd2 : 2'd0;

                        if (candidate_ok) begin
                            if (pending_valid &&
                                (abs_diff9(pending_x0, best_x0) <= 24) &&
                                (abs_diff9(pending_y0, best_y0) <= 24) &&
                                (abs_diff9(pending_x1, best_x1) <= 36) &&
                                (abs_diff9(pending_y1, best_y1) <= 36)) begin
                                if (pending_count != 2'd3)
                                    pending_count <= pending_count + 1'b1;
                                pending_x0 <= best_x0;
                                pending_x1 <= best_x1;
                                pending_y0 <= best_y0;
                                pending_y1 <= best_y1;
                                if (pending_count >= 2'd1) begin
                                    box_valid <= 1'b1;
                                    box_type <= candidate_type;
                                    if (candidate_type == 2'd2) begin
                                        circle_x0 <= ROI_X0 +
                                                     (best_x0 << 2);
                                        circle_x1 <= ROI_X0 +
                                                     (best_x1 << 2) + 3;
                                        circle_y0 <= ROI_Y0 +
                                                     (best_y0 << 2);
                                        circle_y1 <= ROI_Y0 +
                                                     (best_y1 << 2) + 3;
                                        circle_r <=
                                            (((best_x1 - best_x0 + 1'b1) << 2) +
                                             ((best_y1 - best_y0 + 1'b1) << 2)) >> 2;
                                    end else begin
                                        rect_p0_x <= ROI_X0 +
                                                     (verify_min_s_x << 2);
                                        rect_p0_y <= ROI_Y0 +
                                                     (verify_min_s_y << 2);
                                        rect_p1_x <= ROI_X0 +
                                                     (verify_max_d_x << 2);
                                        rect_p1_y <= ROI_Y0 +
                                                     (verify_max_d_y << 2);
                                        rect_p2_x <= ROI_X0 +
                                                     (verify_max_s_x << 2);
                                        rect_p2_y <= ROI_Y0 +
                                                     (verify_max_s_y << 2);
                                        rect_p3_x <= ROI_X0 +
                                                     (verify_min_d_x << 2);
                                        rect_p3_y <= ROI_Y0 +
                                                     (verify_min_d_y << 2);
                                    end
                                end
                            end else begin
                                pending_valid <= 1'b1;
                                pending_count <= 2'd0;
                                pending_x0 <= best_x0;
                                pending_x1 <= best_x1;
                                pending_y0 <= best_y0;
                                pending_y1 <= best_y1;
                            end
                            miss_count <= 2'd0;
                        end else begin
                            if (miss_count == 2'd3) begin
                                box_valid <= 1'b0;
                                pending_valid <= 1'b0;
                                pending_count <= 2'd0;
                            end else
                                miss_count <= miss_count + 1'b1;
                        end
                    end
                    work_state <= S_IDLE;
                end

                default: work_state <= S_IDLE;
            endcase
        end
    end

    // ---------------------------------------------------------------
    // Rendering.  Rectangle corners are the x+y / x-y extremes, which remain
    // attached for axis-aligned and moderately rotated rectangles.  Circles
    // use a squared-distance ring.
    // ---------------------------------------------------------------
    reg        s1_box_valid;
    reg [1:0]  s1_box_type;
    reg [13:0] s1_x, s1_y;
    reg [7:0]  s1_r, s1_g, s1_b;
    reg        s1_vsync, s1_href, s1_hsync;
    reg signed [14:0] s1_l0dx, s1_l0dy;
    reg signed [14:0] s1_l1dx, s1_l1dy;
    reg signed [14:0] s1_l2dx, s1_l2dy;
    reg signed [14:0] s1_l3dx, s1_l3dy;
    reg signed [14:0] s1_p0dx, s1_p0dy;
    reg signed [14:0] s1_p1dx, s1_p1dy;
    reg signed [14:0] s1_p2dx, s1_p2dy;
    reg signed [14:0] s1_p3dx, s1_p3dy;
    reg signed [14:0] s1_cdx, s1_cdy;

    reg signed [30:0] s2_l0a, s2_l0b;
    reg signed [30:0] s2_l1a, s2_l1b;
    reg signed [30:0] s2_l2a, s2_l2b;
    reg signed [30:0] s2_l3a, s2_l3b;
    reg [30:0] s2_tol0, s2_tol1, s2_tol2, s2_tol3;
    reg [27:0] s2_circle_dist;
    reg [13:0] s2_x, s2_y;
    reg        s2_box_valid;
    reg [1:0]  s2_box_type;
    reg [7:0]  s2_r, s2_g, s2_b;
    reg        s2_vsync, s2_href, s2_hsync;

    reg [13:0] circle_center_x;
    reg [13:0] circle_center_y;
    reg [27:0] circle_low2;
    reg [27:0] circle_high2;

    function [14:0] abs15;
        input signed [14:0] v;
        begin
            abs15 = v[14] ? -v : v;
        end
    endfunction

    function [30:0] abs31;
        input signed [30:0] v;
        begin
            abs31 = v[30] ? -v : v;
        end
    endfunction

    wire [14:0] s1_l0len = abs15(s1_l0dx) + abs15(s1_l0dy);
    wire [14:0] s1_l1len = abs15(s1_l1dx) + abs15(s1_l1dy);
    wire [14:0] s1_l2len = abs15(s1_l2dx) + abs15(s1_l2dy);
    wire [14:0] s1_l3len = abs15(s1_l3dx) + abs15(s1_l3dy);
    wire signed [30:0] s2_cross0 = s2_l0a - s2_l0b;
    wire signed [30:0] s2_cross1 = s2_l1a - s2_l1b;
    wire signed [30:0] s2_cross2 = s2_l2a - s2_l2b;
    wire signed [30:0] s2_cross3 = s2_l3a - s2_l3b;
    wire [30:0] s2_across0 = abs31(s2_cross0);
    wire [30:0] s2_across1 = abs31(s2_cross1);
    wire [30:0] s2_across2 = abs31(s2_cross2);
    wire [30:0] s2_across3 = abs31(s2_cross3);

    wire line0_box =
        (s2_x >= ((rect_p0_x < rect_p1_x) ? rect_p0_x : rect_p1_x) - 6) &&
        (s2_x <= ((rect_p0_x > rect_p1_x) ? rect_p0_x : rect_p1_x) + 6) &&
        (s2_y >= ((rect_p0_y < rect_p1_y) ? rect_p0_y : rect_p1_y) - 6) &&
        (s2_y <= ((rect_p0_y > rect_p1_y) ? rect_p0_y : rect_p1_y) + 6);
    wire line1_box =
        (s2_x >= ((rect_p1_x < rect_p2_x) ? rect_p1_x : rect_p2_x) - 6) &&
        (s2_x <= ((rect_p1_x > rect_p2_x) ? rect_p1_x : rect_p2_x) + 6) &&
        (s2_y >= ((rect_p1_y < rect_p2_y) ? rect_p1_y : rect_p2_y) - 6) &&
        (s2_y <= ((rect_p1_y > rect_p2_y) ? rect_p1_y : rect_p2_y) + 6);
    wire line2_box =
        (s2_x >= ((rect_p2_x < rect_p3_x) ? rect_p2_x : rect_p3_x) - 6) &&
        (s2_x <= ((rect_p2_x > rect_p3_x) ? rect_p2_x : rect_p3_x) + 6) &&
        (s2_y >= ((rect_p2_y < rect_p3_y) ? rect_p2_y : rect_p3_y) - 6) &&
        (s2_y <= ((rect_p2_y > rect_p3_y) ? rect_p2_y : rect_p3_y) + 6);
    wire line3_box =
        (s2_x >= ((rect_p3_x < rect_p0_x) ? rect_p3_x : rect_p0_x) - 6) &&
        (s2_x <= ((rect_p3_x > rect_p0_x) ? rect_p3_x : rect_p0_x) + 6) &&
        (s2_y >= ((rect_p3_y < rect_p0_y) ? rect_p3_y : rect_p0_y) - 6) &&
        (s2_y <= ((rect_p3_y > rect_p0_y) ? rect_p3_y : rect_p0_y) + 6);
    wire rect_hit =
        s2_box_valid && (s2_box_type == 2'd1) &&
        ((line0_box && (s2_across0 <= s2_tol0)) ||
         (line1_box && (s2_across1 <= s2_tol1)) ||
         (line2_box && (s2_across2 <= s2_tol2)) ||
         (line3_box && (s2_across3 <= s2_tol3)));
    wire circle_hit =
        s2_box_valid && (s2_box_type == 2'd2) &&
        (s2_circle_dist >= circle_low2) &&
        (s2_circle_dist <= circle_high2);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_box_valid <= 1'b0;
            s1_box_type <= 2'd0;
            s1_x <= 14'd0;
            s1_y <= 14'd0;
            s1_r <= 8'd0;
            s1_g <= 8'd0;
            s1_b <= 8'd0;
            s1_vsync <= 1'b0;
            s1_href <= 1'b0;
            s1_hsync <= 1'b0;
            s1_l0dx <= 15'sd0;
            s1_l0dy <= 15'sd0;
            s1_l1dx <= 15'sd0;
            s1_l1dy <= 15'sd0;
            s1_l2dx <= 15'sd0;
            s1_l2dy <= 15'sd0;
            s1_l3dx <= 15'sd0;
            s1_l3dy <= 15'sd0;
            s1_p0dx <= 15'sd0;
            s1_p0dy <= 15'sd0;
            s1_p1dx <= 15'sd0;
            s1_p1dy <= 15'sd0;
            s1_p2dx <= 15'sd0;
            s1_p2dy <= 15'sd0;
            s1_p3dx <= 15'sd0;
            s1_p3dy <= 15'sd0;
            s1_cdx <= 15'sd0;
            s1_cdy <= 15'sd0;
            s2_l0a <= 31'sd0;
            s2_l0b <= 31'sd0;
            s2_l1a <= 31'sd0;
            s2_l1b <= 31'sd0;
            s2_l2a <= 31'sd0;
            s2_l2b <= 31'sd0;
            s2_l3a <= 31'sd0;
            s2_l3b <= 31'sd0;
            s2_tol0 <= 31'd0;
            s2_tol1 <= 31'd0;
            s2_tol2 <= 31'd0;
            s2_tol3 <= 31'd0;
            s2_circle_dist <= 28'd0;
            s2_x <= 14'd0;
            s2_y <= 14'd0;
            s2_box_valid <= 1'b0;
            s2_box_type <= 2'd0;
            s2_r <= 8'd0;
            s2_g <= 8'd0;
            s2_b <= 8'd0;
            s2_vsync <= 1'b0;
            s2_href <= 1'b0;
            s2_hsync <= 1'b0;
            circle_center_x <= 14'd0;
            circle_center_y <= 14'd0;
            circle_low2 <= 28'd0;
            circle_high2 <= 28'd0;
            post_frame_vsync <= 1'b0;
            post_frame_href <= 1'b0;
            post_frame_hsync <= 1'b0;
            post_img_red <= 8'd0;
            post_img_green <= 8'd0;
            post_img_blue <= 8'd0;
            shape_type <= 2'd0;
        end else begin
            s1_box_valid <= box_valid;
            s1_box_type <= box_type;
            s1_x <= x_cnt;
            s1_y <= y_cnt;
            s1_r <= per_img_red;
            s1_g <= per_img_green;
            s1_b <= per_img_blue;
            s1_vsync <= per_frame_vsync;
            s1_href <= per_frame_href;
            s1_hsync <= per_frame_hsync;
            s1_l0dx <= $signed({1'b0, rect_p1_x}) -
                       $signed({1'b0, rect_p0_x});
            s1_l0dy <= $signed({1'b0, rect_p1_y}) -
                       $signed({1'b0, rect_p0_y});
            s1_l1dx <= $signed({1'b0, rect_p2_x}) -
                       $signed({1'b0, rect_p1_x});
            s1_l1dy <= $signed({1'b0, rect_p2_y}) -
                       $signed({1'b0, rect_p1_y});
            s1_l2dx <= $signed({1'b0, rect_p3_x}) -
                       $signed({1'b0, rect_p2_x});
            s1_l2dy <= $signed({1'b0, rect_p3_y}) -
                       $signed({1'b0, rect_p2_y});
            s1_l3dx <= $signed({1'b0, rect_p0_x}) -
                       $signed({1'b0, rect_p3_x});
            s1_l3dy <= $signed({1'b0, rect_p0_y}) -
                       $signed({1'b0, rect_p3_y});
            s1_p0dx <= $signed({1'b0, x_cnt}) -
                       $signed({1'b0, rect_p0_x});
            s1_p0dy <= $signed({1'b0, y_cnt}) -
                       $signed({1'b0, rect_p0_y});
            s1_p1dx <= $signed({1'b0, x_cnt}) -
                       $signed({1'b0, rect_p1_x});
            s1_p1dy <= $signed({1'b0, y_cnt}) -
                       $signed({1'b0, rect_p1_y});
            s1_p2dx <= $signed({1'b0, x_cnt}) -
                       $signed({1'b0, rect_p2_x});
            s1_p2dy <= $signed({1'b0, y_cnt}) -
                       $signed({1'b0, rect_p2_y});
            s1_p3dx <= $signed({1'b0, x_cnt}) -
                       $signed({1'b0, rect_p3_x});
            s1_p3dy <= $signed({1'b0, y_cnt}) -
                       $signed({1'b0, rect_p3_y});
            s1_cdx <= $signed({1'b0, x_cnt}) -
                      $signed({1'b0, circle_center_x});
            s1_cdy <= $signed({1'b0, y_cnt}) -
                      $signed({1'b0, circle_center_y});

            s2_l0a <= s1_p0dy * s1_l0dx;
            s2_l0b <= s1_p0dx * s1_l0dy;
            s2_l1a <= s1_p1dy * s1_l1dx;
            s2_l1b <= s1_p1dx * s1_l1dy;
            s2_l2a <= s1_p2dy * s1_l2dx;
            s2_l2b <= s1_p2dx * s1_l2dy;
            s2_l3a <= s1_p3dy * s1_l3dx;
            s2_l3b <= s1_p3dx * s1_l3dy;
            s2_tol0 <= {16'd0, s1_l0len} * 5;
            s2_tol1 <= {16'd0, s1_l1len} * 5;
            s2_tol2 <= {16'd0, s1_l2len} * 5;
            s2_tol3 <= {16'd0, s1_l3len} * 5;
            s2_circle_dist <= (s1_cdx * s1_cdx) +
                              (s1_cdy * s1_cdy);
            s2_x <= s1_x;
            s2_y <= s1_y;
            s2_box_valid <= s1_box_valid;
            s2_box_type <= s1_box_type;
            s2_r <= s1_r;
            s2_g <= s1_g;
            s2_b <= s1_b;
            s2_vsync <= s1_vsync;
            s2_href <= s1_href;
            s2_hsync <= s1_hsync;

            post_frame_vsync <= s2_vsync;
            post_frame_href <= s2_href;
            post_frame_hsync <= s2_hsync;
            if (rect_hit) begin
                post_img_red <= 8'hFF;
                post_img_green <= 8'hFF;
                post_img_blue <= 8'h00;
            end else if (circle_hit) begin
                post_img_red <= 8'h00;
                post_img_green <= 8'hFF;
                post_img_blue <= 8'hFF;
            end else begin
                post_img_red <= s2_r;
                post_img_green <= s2_g;
                post_img_blue <= s2_b;
            end
            shape_type <= box_valid ? box_type : 2'd0;

            circle_center_x <= (circle_x0 + circle_x1) >> 1;
            circle_center_y <= (circle_y0 + circle_y1) >> 1;
            circle_low2 <= (circle_r * circle_r) -
                           ((circle_r > 1) ? (circle_r << 2) : 0);
            circle_high2 <= (circle_r * circle_r) +
                            ((circle_r > 1) ? (circle_r << 2) : 0);
        end
    end

    assign circle_count_out =
        (box_valid && (box_type == 2'd2)) ? 4'd1 : 4'd0;
    assign rect_count_out =
        (box_valid && (box_type == 2'd1)) ? 4'd1 : 4'd0;

endmodule
