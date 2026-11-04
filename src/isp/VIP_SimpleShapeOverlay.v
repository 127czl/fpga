`timescale 1ns/1ps

// Task 9 shape recogniser.
//
// The previous implementation measured one global bounding box over every
// edge pixel in a central window.  A few background edges therefore expanded
// the box to the window border, so a visible circle or rectangle was never
// represented by a useful candidate.
//
// This version first reduces the edge stream to 32x32 occupancy cells.  A
// cell is valid only when enough edge pixels pass through it.  The valid cells
// are then connected with a very small row-run tracker.  That gives us real
// object statistics instead of one frame-wide box:
//
//   - the object bounding box is built only from connected cells
//   - the longest horizontal run separates rectangles from circles
//   - objects smaller than 1/8 of the display are discarded
//   - near-frame-sized objects are discarded
//
// The generated outline is still drawn by VIP_ShapeOutlinePixel, so a
// rectangle becomes four straight sides and a circle becomes a real circular
// ring.
module VIP_SimpleShapeOverlay #(
    parameter [13:0] IMG_HDISP = 14'd1920,
    parameter [13:0] IMG_VDISP = 14'd1080,
    parameter [13:0] ROI_X0 = 14'd320,
    parameter [13:0] ROI_X1 = 14'd1599,
    parameter [13:0] ROI_Y0 = 14'd180,
    parameter [13:0] ROI_Y1 = 14'd899,
    parameter [13:0] CORE_MARGIN = 14'd24,
    parameter [21:0] MIN_EDGE = 22'd8,
    parameter [21:0] MAX_EDGE = 22'd8192,
    parameter [27:0] MIN_BOX_AREA = 28'd259200,
    parameter [13:0] MIN_SIDE = 14'd300,
    parameter [13:0] MAX_WIDTH = 14'd1536,
    parameter [13:0] MAX_HEIGHT = 14'd864,
    parameter [13:0] BOUNDARY_GUARD = 14'd32,
    parameter [4:0] MAX_OBJ = 5'd24
    )(
    input               clk,
    input               rst_n,

    input               per_frame_vsync,
    input               per_frame_href,
    input               per_frame_hsync,
    input               per_img_edge,
    input       [7:0]   per_img_red,
    input       [7:0]   per_img_green,
    input       [7:0]   per_img_blue,

    output reg          post_frame_vsync,
    output reg          post_frame_href,
    output reg          post_frame_hsync,
    output reg  [7:0]   post_img_red,
    output reg  [7:0]   post_img_green,
    output reg  [7:0]   post_img_blue,
    output reg  [1:0]   shape_type
    );

    localparam [7:0] GRID_W = (IMG_HDISP + 14'd31) >> 5;
    localparam [7:0] GRID_H = (IMG_VDISP + 14'd31) >> 5;
    localparam [13:0] ACTIVE_X0 = ROI_X0 + CORE_MARGIN;
    localparam [13:0] ACTIVE_X1 = ROI_X1 - CORE_MARGIN;
    localparam [13:0] ACTIVE_Y0 = ROI_Y0 + CORE_MARGIN;
    localparam [13:0] ACTIVE_Y1 = ROI_Y1 - CORE_MARGIN;

    localparam [2:0] S_IDLE   = 3'd0;
    localparam [2:0] S_SCAN   = 3'd1;
    localparam [2:0] S_PEND   = 3'd2;
    localparam [2:0] S_ROWEND = 3'd3;
    localparam [2:0] S_CLASS  = 3'd4;
    localparam [2:0] S_LOAD   = 3'd5;
    localparam [2:0] S_MATCH  = 3'd6;

    // 60 x 34 one-bit cells for 1920 x 1080.  This keeps the recogniser
    // comfortably inside the Ti60 logic capacity while still giving enough
    // resolution for a 300-pixel object.
    reg [GRID_W-1:0] row_bitmap [0:GRID_H-1];

    reg [13:0] x_cnt, y_cnt;
    reg        href_d, vsync_d;
    reg [5:0]  cell_edge_count;

    wire       vsync_rise = per_frame_vsync && !vsync_d;
    wire       vsync_fall = vsync_d && !per_frame_vsync;
    wire       href_rise  = per_frame_href && !href_d;
    wire       cell_done  = per_frame_href && (x_cnt[4:0] == 5'h1F);
    wire       in_roi     = per_frame_href && per_frame_vsync &&
                            (x_cnt >= ACTIVE_X0) && (x_cnt <= ACTIVE_X1) &&
                            (y_cnt >= ACTIVE_Y0) && (y_cnt <= ACTIVE_Y1);
    wire [5:0] cell_edge_now = cell_edge_count +
                               ((in_roi && per_img_edge) ? 6'd1 : 6'd0);
    wire       cell_valid_now = (cell_edge_now >= MIN_EDGE[5:0]);

    wire [7:0] cell_x = x_cnt[10:5];
    wire [7:0] cell_y = y_cnt[10:5];

    // Connected-object records.  Coordinates are cell coordinates, not pixel
    // coordinates, until the final drawing stage.
    reg        obj_valid [0:MAX_OBJ-1];
    reg [7:0]  obj_x0 [0:MAX_OBJ-1];
    reg [7:0]  obj_x1 [0:MAX_OBJ-1];
    reg [7:0]  obj_y0 [0:MAX_OBJ-1];
    reg [7:0]  obj_last_y [0:MAX_OBJ-1];
    reg [15:0] obj_area [0:MAX_OBJ-1];
    reg [7:0]  obj_max_run [0:MAX_OBJ-1];
    reg [4:0]  obj_alloc;

    reg [2:0]  scan_state;
    reg [7:0]  scan_row;
    reg [7:0]  scan_col;
    reg        run_active;
    reg [7:0]  run_x0, run_x1;
    reg        pend_valid;
    reg        row_end_pending;
    reg [7:0]  pend_x0, pend_x1, pend_y;
    reg [4:0]  pend_match_r;

    reg [4:0]  cls_k;
    reg        best_valid;
    reg [7:0]  best_x0, best_x1, best_y0, best_y1;
    reg [1:0]  best_type;
    reg [27:0] best_area;

    // Registered candidate being classified.  This keeps the object-array
    // muxes, the area multiplier, and the comparison pipeline separate.
    reg        cand_valid_r;
    reg [7:0]  cand_x0_r, cand_x1_r, cand_y0_r, cand_last_y_r;
    reg [15:0] cand_area_r;
    reg [7:0]  cand_max_run_r;

    reg [13:0] box_x0, box_x1, box_y0, box_y1;
    reg        box_valid;
    reg [1:0]  box_type;

    integer    i;

    // Match a run to an object touched on the previous row or two.  The small
    // gap tolerance is the block-level equivalent of an 8-connected CCL.
    function [4:0] find_object;
        input [7:0] x0;
        input [7:0] x1;
        input [7:0] y;
        integer n;
        reg row_ok;
        begin
            find_object = 5'h1F;
            for (n = 0; n < MAX_OBJ; n = n + 1) begin
                row_ok = (obj_last_y[n] <= y) &&
                         ((obj_last_y[n] + 8'd1) >= y);
                if (obj_valid[n] && row_ok &&
                    (x0 <= (obj_x1[n] + 8'd2)) &&
                    ((x1 + 8'd2) >= obj_x0[n]))
                    find_object = n[4:0];
            end
        end
    endfunction

    wire [4:0] pend_match = find_object(pend_x0, pend_x1, pend_y);

    // ---------------------------------------------------------------
    // Pixel counters and occupancy-cell generation
    // ---------------------------------------------------------------
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

    // ---------------------------------------------------------------
    // Frame capture, occupancy clear, and frame-end CCL scan
    // ---------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < GRID_H; i = i + 1)
                row_bitmap[i] <= {GRID_W{1'b0}};
            cell_edge_count <= 6'd0;
            obj_alloc <= 5'd0;
            scan_state <= S_IDLE;
            scan_row <= 8'd0;
            scan_col <= 8'd0;
            run_active <= 1'b0;
            run_x0 <= 8'd0;
            run_x1 <= 8'd0;
            pend_valid <= 1'b0;
            row_end_pending <= 1'b0;
            pend_x0 <= 8'd0;
            pend_x1 <= 8'd0;
            pend_y <= 8'd0;
            pend_match_r <= 5'h1F;
            cls_k <= 5'd0;
            best_valid <= 1'b0;
            best_x0 <= 8'd0;
            best_x1 <= 8'd0;
            best_y0 <= 8'd0;
            best_y1 <= 8'd0;
            best_type <= 2'd0;
            best_area <= 28'd0;
            cand_valid_r <= 1'b0;
            cand_x0_r <= 8'd0;
            cand_x1_r <= 8'd0;
            cand_y0_r <= 8'd0;
            cand_last_y_r <= 8'd0;
            cand_area_r <= 16'd0;
            cand_max_run_r <= 8'd0;
            box_x0 <= 14'd0;
            box_x1 <= 14'd0;
            box_y0 <= 14'd0;
            box_y1 <= 14'd0;
            box_valid <= 1'b0;
            box_type <= 2'd0;
            for (i = 0; i < MAX_OBJ; i = i + 1) begin
                obj_valid[i] <= 1'b0;
                obj_x0[i] <= 8'd0;
                obj_x1[i] <= 8'd0;
                obj_y0[i] <= 8'd0;
                obj_last_y[i] <= 8'd0;
                obj_area[i] <= 16'd0;
                obj_max_run[i] <= 8'd0;
            end
        end else if (vsync_rise) begin
            // A completed frame has already been scanned in the vblank.  Clear
            // the occupancy map for the next frame.
            for (i = 0; i < GRID_H; i = i + 1)
                row_bitmap[i] <= {GRID_W{1'b0}};
            cell_edge_count <= 6'd0;
            scan_state <= S_IDLE;
            scan_row <= 8'd0;
            scan_col <= 8'd0;
            run_active <= 1'b0;
            pend_valid <= 1'b0;
            row_end_pending <= 1'b0;
        end else begin
            // Record one occupancy bit at the end of each 32-pixel cell.
            if (in_roi && per_img_edge)
                cell_edge_count <= cell_edge_count + 1'b1;
            if (cell_done) begin
                row_bitmap[cell_y][cell_x] <= cell_valid_now;
                cell_edge_count <= 6'd0;
            end

            case (scan_state)
                S_IDLE: begin
                    if (vsync_fall) begin
                        // Start a new CCL pass over the bitmap captured during
                        // the active frame.
                        scan_row <= 8'd0;
                        scan_col <= 8'd0;
                        run_active <= 1'b0;
                        pend_valid <= 1'b0;
                        row_end_pending <= 1'b0;
                        obj_alloc <= 5'd0;
                        for (i = 0; i < MAX_OBJ; i = i + 1) begin
                            obj_valid[i] <= 1'b0;
                            obj_x0[i] <= 8'd0;
                            obj_x1[i] <= 8'd0;
                            obj_y0[i] <= 8'd0;
                            obj_last_y[i] <= 8'd0;
                            obj_area[i] <= 16'd0;
                            obj_max_run[i] <= 8'd0;
                        end
                        scan_state <= S_SCAN;
                    end
                end

                S_SCAN: begin
                    if (scan_col < GRID_W) begin
                        if (row_bitmap[scan_row][scan_col]) begin
                            if (!run_active) begin
                                run_active <= 1'b1;
                                run_x0 <= scan_col;
                                run_x1 <= scan_col;
                            end else begin
                                run_x1 <= scan_col;
                            end
                            scan_col <= scan_col + 1'b1;
                        end else if (run_active) begin
                            pend_x0 <= run_x0;
                            pend_x1 <= run_x1;
                            pend_y <= scan_row;
                            pend_valid <= 1'b1;
                            run_active <= 1'b0;
                            scan_col <= scan_col + 1'b1;
                            scan_state <= S_MATCH;
                        end else begin
                            scan_col <= scan_col + 1'b1;
                        end
                    end else begin
                        if (run_active) begin
                            pend_x0 <= run_x0;
                            pend_x1 <= run_x1;
                            pend_y <= scan_row;
                            pend_valid <= 1'b1;
                            row_end_pending <= 1'b1;
                            run_active <= 1'b0;
                            scan_state <= S_MATCH;
                        end else begin
                            scan_state <= S_ROWEND;
                        end
                    end
                end

                S_MATCH: begin
                    pend_match_r <= pend_match;
                    scan_state <= S_PEND;
                end

                S_PEND: begin
                    if (pend_valid) begin
                        if (pend_match_r != 5'h1F) begin
                            if (pend_x0 < obj_x0[pend_match_r])
                                obj_x0[pend_match_r] <= pend_x0;
                            if (pend_x1 > obj_x1[pend_match_r])
                                obj_x1[pend_match_r] <= pend_x1;
                            if (pend_y > obj_last_y[pend_match_r])
                                obj_last_y[pend_match_r] <= pend_y;
                            obj_area[pend_match_r] <= obj_area[pend_match_r] +
                                                    (pend_x1 - pend_x0 + 1'b1);
                            if ((pend_x1 - pend_x0 + 1'b1) >
                                obj_max_run[pend_match_r])
                                obj_max_run[pend_match_r] <=
                                    pend_x1 - pend_x0 + 1'b1;
                        end else if (obj_alloc < MAX_OBJ) begin
                            obj_valid[obj_alloc] <= 1'b1;
                            obj_x0[obj_alloc] <= pend_x0;
                            obj_x1[obj_alloc] <= pend_x1;
                            obj_y0[obj_alloc] <= pend_y;
                            obj_last_y[obj_alloc] <= pend_y;
                            obj_area[obj_alloc] <= pend_x1 - pend_x0 + 1'b1;
                            obj_max_run[obj_alloc] <= pend_x1 - pend_x0 + 1'b1;
                            obj_alloc <= obj_alloc + 1'b1;
                        end
                    end
                    pend_valid <= 1'b0;

                    if (row_end_pending) begin
                        row_end_pending <= 1'b0;
                        if (scan_row == GRID_H - 1'b1) begin
                            cls_k <= 5'd0;
                            best_valid <= 1'b0;
                            best_area <= 28'd0;
                            scan_state <= S_CLASS;
                        end else begin
                            scan_row <= scan_row + 1'b1;
                            scan_col <= 8'd0;
                            scan_state <= S_SCAN;
                        end
                    end else begin
                        scan_state <= S_SCAN;
                    end
                end

                S_ROWEND: begin
                    if (scan_row == GRID_H - 1'b1) begin
                        cls_k <= 5'd0;
                        best_valid <= 1'b0;
                        best_area <= 28'd0;
                        scan_state <= S_CLASS;
                    end else begin
                        scan_row <= scan_row + 1'b1;
                        scan_col <= 8'd0;
                        scan_state <= S_SCAN;
                    end
                end

                S_CLASS: begin
                    if (cls_k < MAX_OBJ) begin
                        cand_valid_r   <= obj_valid[cls_k];
                        cand_x0_r      <= obj_x0[cls_k];
                        cand_x1_r      <= obj_x1[cls_k];
                        cand_y0_r      <= obj_y0[cls_k];
                        cand_last_y_r  <= obj_last_y[cls_k];
                        cand_area_r    <= obj_area[cls_k];
                        cand_max_run_r <= obj_max_run[cls_k];
                        cls_k <= cls_k + 1'b1;
                        scan_state <= S_LOAD;
                    end else begin
                        box_valid <= best_valid;
                        box_type <= best_valid ? best_type : 2'd0;
                        box_x0 <= {6'b0, best_x0} << 5;
                        box_x1 <= ({6'b0, (best_x1 + 8'd1)} << 5) - 1'b1;
                        box_y0 <= {6'b0, best_y0} << 5;
                        box_y1 <= ({6'b0, (best_y1 + 8'd1)} << 5) - 1'b1;
                        scan_state <= S_IDLE;
                    end
                end

                S_LOAD: begin
                    if (cand_box_ok && (cand_box_area > best_area)) begin
                        best_valid <= 1'b1;
                        best_x0 <= cand_x0_r;
                        best_x1 <= cand_x1_r;
                        best_y0 <= cand_y0_r;
                        best_y1 <= cand_last_y_r;
                        best_type <= cand_type;
                        best_area <= cand_box_area;
                    end
                    scan_state <= S_CLASS;
                end

                default: scan_state <= S_IDLE;
            endcase
        end
    end

    // Candidate classification is evaluated from registered candidate fields.
    // This keeps the object-array muxes out of the multiplier/comparator path.
    wire [7:0]  cand_w  = cand_x1_r - cand_x0_r + 1'b1;
    wire [7:0]  cand_h  = cand_last_y_r - cand_y0_r + 1'b1;
    wire [13:0] cand_px_w = {6'b0, cand_w} << 5;
    wire [13:0] cand_px_h = {6'b0, cand_h} << 5;
    wire [27:0] cand_box_area = cand_px_w * cand_px_h;
    wire        cand_square = (cand_px_w * 4 > cand_px_h * 3) &&
                              (cand_px_h * 4 > cand_px_w * 3);
    // A rectangle has a long horizontal side.  A circle may also produce a
    // moderately long run near its top/bottom cap, so require the run to cover
    // at least two thirds of the object width before calling it a rectangle.
    wire        cand_rect = (cand_max_run_r * 3) > (cand_w * 2);
    wire        cand_circle = !cand_rect && cand_square &&
                              (cand_area_r <= ((cand_w + cand_h) * 3));
    wire        cand_size_ok = (cand_px_w >= MIN_SIDE) &&
                               (cand_px_h >= MIN_SIDE) &&
                               (cand_px_w <= MAX_WIDTH) &&
                               (cand_px_h <= MAX_HEIGHT);
    wire        cand_area_ok = (cand_box_area >= MIN_BOX_AREA) &&
                               (cand_box_area <= 28'd1555200);
    wire        cand_box_ok = cand_valid_r &&
                              (cand_area_r >= MIN_EDGE[15:0]) &&
                              (cand_area_r <= MAX_EDGE[15:0]) &&
                              cand_size_ok && cand_area_ok &&
                              (cand_x0_r > (BOUNDARY_GUARD[7:0] >> 5)) &&
                              (cand_x1_r < (GRID_W - 1'b1)) &&
                              (cand_y0_r > (BOUNDARY_GUARD[7:0] >> 5)) &&
                              (cand_last_y_r < (GRID_H - 1'b1));
    wire [1:0]  cand_type = !cand_box_ok ? 2'd0 :
                            cand_rect      ? 2'd1 :
                            cand_circle    ? 2'd2 : 2'd0;

    // ---------------------------------------------------------------
    // Drawing and output
    // ---------------------------------------------------------------
    wire rect_on, circle_on;
    VIP_ShapeOutlinePixel u_outline (
        .clk        (clk),
        .rst_n      (rst_n),
        .x_cnt      (x_cnt),
        .y_cnt      (y_cnt),
        .valid      (box_valid),
        .shape_type (box_type),
        .x0         (box_x0),
        .x1         (box_x1),
        .y0         (box_y0),
        .y1         (box_y1),
        .rect_on    (rect_on),
        .circle_on  (circle_on)
    );

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

            if (rect_on) begin
                post_img_red   <= 8'hFF;
                post_img_green <= 8'hFF;
                post_img_blue  <= 8'h00;
            end else if (circle_on) begin
                post_img_red   <= 8'h00;
                post_img_green <= 8'hFF;
                post_img_blue  <= 8'hFF;
            end else begin
                post_img_red   <= per_img_red;
                post_img_green <= per_img_green;
                post_img_blue  <= per_img_blue;
            end

            shape_type <= box_valid ? box_type : 2'd0;
        end
    end

endmodule
