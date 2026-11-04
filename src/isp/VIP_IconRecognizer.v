`timescale 1ns/1ps

// Task 7: recogniser for the six supplied demo warning-sign cards.
//
// Frame N measures the red/blue sign border and builds a candidate box.
// Frame N+1 samples a 16x16 colour grid inside that box.
// During vertical blanking the sample vector is compared with six 16x16
// templates in icon_templates.mem.
//
// v84w: the 16 cell centres are placed on exact band centres
// (x0 + w*(2i+1)/32).  The old x0 + (step>>1) + i*step with step = w>>4
// only covered 16*(w>>4) pixels, so a 92 px wide sign was measured over
// 80 px and the feature vector was compressed towards the centre.
//
// v84x: candidate box from red/blue only, 6+ pixel run filter, 3<->5 class
// remap removed (label ROM is in natural order), 9-bit distance counters and
// the last confirmed class is held until a new evaluation so the box/label do
// not blink at half the frame rate.  A grey box marks "detected, no match".
//
// v84y: colour front-end rewritten around chroma/channel ordering because the
// live camera image is heavily desaturated (a printed red reads about
// 205,158,161), which made every absolute threshold miss the sign.
//
// v84z: 2x chroma boost before classification (the live image also has a
// brightness gradient, so part of a red ring fell below the chroma threshold
// and the box was short), and the "detected but unknown" box is yellow now.
//
// v85d: the other five classes use the existing template path unchanged.
// The parking sign has a uniquely large solid-blue field, so a weak-blue
// candidate detector and a 25% blue-area vote keep that class from failing
// when the SC2210 desaturates the blue print.
//
// v85f: parking no longer depends on the generic candidate or template
// distance succeeding.  A separate low-saturation blue run accumulator
// measures a square blue region directly in the ROI and confirms class 5
// as soon as that region is stable.  The other five classes are untouched.
module VIP_IconRecognizer #(
    parameter [13:0] IMG_HDISP = 14'd1920,
    parameter [13:0] IMG_VDISP = 14'd1080,
    parameter [13:0] ROI_X0 = 14'd792,
    parameter [13:0] ROI_X1 = 14'd1127,
    parameter [13:0] ROI_Y0 = 14'd372,
    parameter [13:0] ROI_Y1 = 14'd707,
    parameter [7:0]  MAX_TEMPLATE_DISTANCE = 8'd104,
    parameter [8:0]  BEST_CLASS_MARGIN = 9'd2
    )(
    input               clk,
    input               rst_n,
    input       [2:0]   cfg_diag_mode,

    input               per_frame_vsync,
    input               per_frame_href,
    input               per_frame_hsync,
    input       [7:0]   per_img_red,
    input       [7:0]   per_img_green,
    input       [7:0]   per_img_blue,

    output reg          post_frame_vsync,
    output reg          post_frame_href,
    output reg          post_frame_hsync,
    output reg  [7:0]   post_img_red,
    output reg  [7:0]   post_img_green,
    output reg  [7:0]   post_img_blue,
    output reg  [2:0]   icon_class,
    output reg          icon_valid
    );

    localparam [1:0] M_DETECT = 2'd0;
    localparam [1:0] M_SAMPLE = 2'd1;
    localparam [1:0] M_EVAL   = 2'd2;

    reg [13:0] x_cnt, y_cnt;
    reg href_d, vsync_d;
    wire href_rise = per_frame_href && !href_d;
    wire vsync_rise = per_frame_vsync && !vsync_d;
    wire vsync_fall = vsync_d && !per_frame_vsync;

    wire [13:0] roi_x0 = ROI_X0;
    wire [13:0] roi_x1 = ROI_X1;
    wire [13:0] roi_y0 = ROI_Y0;
    wire [13:0] roi_y1 = ROI_Y1;

    wire in_roi = per_frame_href && per_frame_vsync &&
                  (x_cnt >= roi_x0) && (x_cnt <= roi_x1) &&
                  (y_cnt >= roi_y0) && (y_cnt <= roi_y1);

    // Detection and classification use deliberately different thresholds.
    // The live SC2210 image is desaturated, but warm white paper still has
    // a small red bias.  Require a real channel separation as well as chroma
    // so tinted paper cannot become a red candidate.
    wire [7:0] rg_max = (per_img_red > per_img_green) ? per_img_red : per_img_green;
    wire [7:0] rg_min = (per_img_red < per_img_green) ? per_img_red : per_img_green;
    wire [7:0] pix_max = (rg_max > per_img_blue) ? rg_max : per_img_blue;
    wire [7:0] pix_min = (rg_min < per_img_blue) ? rg_min : per_img_blue;
    wire [7:0] pix_chroma = pix_max - pix_min;

    wire black_pix = in_roi &&
                     (pix_max <= 8'd100) && (pix_chroma < 8'd28);
    wire colored_pix = in_roi && !black_pix &&
                       (pix_chroma >= 8'd35) && (pix_max >= 8'd75);
    wire yellow_pix = colored_pix &&
                      ({1'b0, per_img_red} >= ({1'b0, per_img_blue} + 9'd35)) &&
                      ({1'b0, per_img_green} >= ({1'b0, per_img_blue} + 9'd30)) &&
                      (per_img_green >= 8'd85);
    wire blue_pix = colored_pix &&
                    ({1'b0, per_img_blue} >= ({1'b0, per_img_red} + 9'd25)) &&
                    ({1'b0, per_img_blue} >= ({1'b0, per_img_green} + 9'd20)) &&
                    (per_img_blue >= 8'd80);
    wire soft_blue_pix = in_roi && !black_pix &&
                         (pix_chroma >= 8'd18) && (per_img_blue >= 8'd55) &&
                         ({1'b0, per_img_blue} >= ({1'b0, per_img_red} + 9'd12)) &&
                         ({1'b0, per_img_blue} >= ({1'b0, per_img_green} + 9'd8));
    // Parking is the only supplied sign with a large blue field.  This
    // deliberately tolerant detector survives a nearly-grey SC2210 blue
    // without widening the red candidate detector used by the other signs.
    wire parking_blue_pix = in_roi && !black_pix &&
                            (pix_chroma >= 8'd8) &&
                            (per_img_blue >= 8'd24) && (pix_max <= 8'd220) &&
                            ({1'b0, per_img_blue} >= ({1'b0, per_img_red} + 9'd4)) &&
                            ({1'b0, per_img_blue} >= ({1'b0, per_img_green} + 9'd2));
    wire red_pix = colored_pix && !yellow_pix && !blue_pix &&
                   ({1'b0, per_img_red} >= ({1'b0, per_img_green} + 9'd20)) &&
                   ({1'b0, per_img_red} >= ({1'b0, per_img_blue} + 9'd20)) &&
                   (per_img_red >= 8'd95);
    // The five template signs all have a red outer border.  Parking is the
    // only blue sign and has its own independent blue-region detector below.
    // Do not feed soft-blue paper/background pixels into the generic box:
    // one broad low-saturation run could otherwise make a full-size card fail
    // while a cropped corner happened to produce a smaller, valid box.
    wire border_pix = red_pix;

    // Stricter model for the 16x16 template signature.  White paper is
    // neutral (chroma well below 30), the printed yellow is strongly
    // chromatic (chroma 80+), and the black icon is dark and colourless.
    wire s_black = in_roi && (pix_max <= 8'd110) && (pix_chroma < 8'd32);
    wire s_colored = in_roi && !s_black &&
                     (pix_chroma >= 8'd35) && (pix_max >= 8'd80);
    wire s_yellow = s_colored && (pix_chroma >= 8'd45) &&
                    ({1'b0, per_img_red} >= ({1'b0, per_img_blue} + 9'd30)) &&
                    ({1'b0, per_img_green} >= ({1'b0, per_img_blue} + 9'd25)) &&
                    (per_img_green >= 8'd85);
    wire s_blue = s_colored &&
                  ({1'b0, per_img_blue} >= ({1'b0, per_img_red} + 9'd20)) &&
                  ({1'b0, per_img_blue} >= ({1'b0, per_img_green} + 9'd18)) &&
                  (per_img_blue >= 8'd80);
    wire s_red = s_colored && !s_yellow && !s_blue &&
                 ({1'b0, per_img_red} >= ({1'b0, per_img_green} + 9'd18)) &&
                 ({1'b0, per_img_red} >= ({1'b0, per_img_blue} + 9'd18)) &&
                 (per_img_red >= 8'd90);

    reg [2:0] sample_cat;
    always @(*) begin
        if (s_red)
            sample_cat = 3'd2;
        else if (s_blue)
            sample_cat = 3'd4;
        else if (s_yellow)
            sample_cat = 3'd3;
        else if (s_black)
            sample_cat = 3'd1;
        else
            sample_cat = 3'd0;
    end

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
            end else
                x_cnt <= 14'd0;
            if (href_rise && per_frame_vsync) begin
                if (y_cnt < IMG_VDISP - 1'b1)
                    y_cnt <= y_cnt + 1'b1;
            end else if (!per_frame_vsync)
                y_cnt <= 14'd0;
        end
    end

    reg [1:0] mode;
    reg [13:0] det_min_x, det_max_x, det_min_y, det_max_y;
    reg [15:0] det_count;
    reg        run_active;
    reg        run_soft_blue_only;
    reg [13:0] run_start_x;
    reg [13:0] run_len;

    reg cand_valid;
    reg [13:0] cand_x0, cand_x1, cand_y0, cand_y1;
    reg [13:0] center_x [0:15];
    reg [13:0] center_y [0:15];
    reg [2:0] samples_c [0:255];
    reg [2:0] samples_l [0:255];
    reg [2:0] samples_r [0:255];
    reg [2:0] samples_u [0:255];
    reg [2:0] samples_d [0:255];
    reg [13:0] sample_dx, sample_dy;
    reg        calc_busy;
    reg [4:0]  calc_idx;
    reg [15:0] calc_acc_x, calc_acc_y;
    reg [13:0] calc_w, calc_h;
    reg [255:0] red_cells, blue_cells, yellow_cells;
    reg [255:0] black_cells, white_cells;
    reg [13:0] bound_x [0:14];
    reg [13:0] bound_y [0:14];

    reg [2:0] template_mem [0:1535];
    initial $readmemh("src/isp/icon_templates.mem", template_mem);

    reg [2:0] eval_class;
    reg [7:0] eval_idx;
    reg [8:0] eval_dist;
    reg [8:0] best_dist;
    reg [8:0] second_dist;
    reg [2:0] best_class;
    reg [8:0] dist_class3, dist_class4;
    reg [8:0] circle_black_hits;
    reg        eval_mismatch_r;
    reg [2:0] last_class;
    reg       last_valid;
    reg [1:0] stable_count;
    reg [15:0] cand_red_count, cand_blue_count;
    reg [15:0] cand_yellow_count, cand_black_count;
    reg [27:0] cand_area;
    reg cand_parking_direct;
    reg parking_run_active;
    reg [13:0] parking_run_start;
    reg [13:0] parking_run_len;
    reg [15:0] parking_pixel_count;
    reg [15:0] parking_total_count;
    reg        parking_live_valid;
    reg [13:0] parking_min_x, parking_max_x;
    reg [13:0] parking_min_y, parking_max_y;
    reg [13:0] parking_total_min_x, parking_total_max_x;
    reg [13:0] parking_total_min_y, parking_total_max_y;
    reg [15:0] black_zone [0:8];
    reg [13:0] zone_x1, zone_x2, zone_y1, zone_y2;

    wire [13:0] parking_w =
        (parking_max_x >= parking_min_x) ?
        (parking_max_x - parking_min_x + 1'b1) : 14'd0;
    wire [13:0] parking_h =
        (parking_max_y >= parking_min_y) ?
        (parking_max_y - parking_min_y + 1'b1) : 14'd0;
    wire [13:0] parking_dense_w =
        ({2'b00, parking_w} << 3) + ({2'b00, parking_w} << 2);
    wire [13:0] parking_dense_h =
        ({2'b00, parking_h} << 3) + ({2'b00, parking_h} << 2);
    wire parking_region_valid =
        (parking_pixel_count >= 16'd256) &&
        (parking_pixel_count >= parking_dense_w) &&
        (parking_pixel_count >= parking_dense_h) &&
        (parking_w >= 14'd64) && (parking_h >= 14'd64) &&
        (parking_w <= 14'd1000) && (parking_h <= 14'd1000) &&
        ({1'b0, parking_w} <= ({1'b0, parking_h} << 1)) &&
        ({1'b0, parking_h} <= ({1'b0, parking_w} << 1)) &&
        (parking_min_x > roi_x0) &&
        (parking_max_x < roi_x1) &&
        (parking_min_y > roi_y0) &&
        (parking_max_y < roi_y1);
    wire [13:0] active_roi_w = roi_x1 - roi_x0 + 1'b1;
    wire [13:0] active_roi_h = roi_y1 - roi_y0 + 1'b1;
    wire [13:0] active_roi_dense_w =
        ({2'b00, active_roi_w} << 3) + ({2'b00, active_roi_w} << 2);
    wire [13:0] active_roi_dense_h =
        ({2'b00, active_roi_h} << 3) + ({2'b00, active_roi_h} << 2);
    wire [13:0] parking_total_w =
        (parking_total_max_x >= parking_total_min_x) ?
        (parking_total_max_x - parking_total_min_x + 1'b1) : 14'd0;
    wire [13:0] parking_total_h =
        (parking_total_max_y >= parking_total_min_y) ?
        (parking_total_max_y - parking_total_min_y + 1'b1) : 14'd0;
    wire parking_total_box_ready =
        (parking_total_count >= 16'd1500) &&
        (parking_total_count >= active_roi_dense_w) &&
        (parking_total_count >= active_roi_dense_h) &&
        (parking_total_w >= 14'd64) && (parking_total_h >= 14'd64) &&
        (parking_total_w <= 14'd1000) && (parking_total_h <= 14'd1000) &&
        ({1'b0, parking_total_w} <= ({1'b0, parking_total_h} << 1)) &&
        ({1'b0, parking_total_h} <= ({1'b0, parking_total_w} << 1)) &&
        (parking_total_min_x > roi_x0) &&
        (parking_total_max_x < roi_x1) &&
        (parking_total_min_y > roi_y0) &&
        (parking_total_max_y < roi_y1);

    function [2:0] majority5;
        input [2:0] c, l, r, u, d;
        reg [2:0] matches;
        begin
            matches = {2'd0, (l == c)} + {2'd0, (r == c)} +
                      {2'd0, (u == c)} + {2'd0, (d == c)};
            if (matches >= 3'd2)
                majority5 = c;
            else if (l == r)
                majority5 = l;
            else if (u == d)
                majority5 = u;
            else
                majority5 = c;
        end
    endfunction

    // Evaluation pipeline (3 phases per cell):
    //   0) drive address, capture the 5 samples + template into registers
    //   1) majority vote + compare, capture one mismatch bit
    //   2) accumulate the distance / finish the class
    reg [1:0]  eval_ph;
    reg [14:0] eval_word_r;
    reg [2:0]  eval_tmpl_r;

    wire [2:0] cat_c = eval_word_r[14:12];
    wire [2:0] cat_l = eval_word_r[11:9];
    wire [2:0] cat_r = eval_word_r[8:6];
    wire [2:0] cat_u = eval_word_r[5:3];
    wire [2:0] cat_d = eval_word_r[2:0];
    wire [2:0] cell_category = majority5(cat_c, cat_l, cat_r, cat_u, cat_d);

    integer i;
    integer j;

    // Centre lookup for five-point sampling of each 16x16 cell.
    reg x_hit, y_hit;
    reg [3:0] sample_x, sample_y;
    reg [1:0] x_sel, y_sel;
    always @(*) begin
        x_hit = 1'b0;
        y_hit = 1'b0;
        sample_x = 4'd0;
        sample_y = 4'd0;
        x_sel = 2'd1;
        y_sel = 2'd1;
        for (i = 0; i < 16; i = i + 1) begin
            if (x_cnt == center_x[i]) begin
                x_hit = 1'b1;
                sample_x = i[3:0];
                x_sel = 2'd1;
            end else if ((center_x[i] >= sample_dx) &&
                         (x_cnt == center_x[i] - sample_dx)) begin
                x_hit = 1'b1;
                sample_x = i[3:0];
                x_sel = 2'd0;
            end else if (x_cnt == center_x[i] + sample_dx) begin
                x_hit = 1'b1;
                sample_x = i[3:0];
                x_sel = 2'd2;
            end
            if (y_cnt == center_y[i]) begin
                y_hit = 1'b1;
                sample_y = i[3:0];
                y_sel = 2'd1;
            end else if ((center_y[i] >= sample_dy) &&
                         (y_cnt == center_y[i] - sample_dy)) begin
                y_hit = 1'b1;
                sample_y = i[3:0];
                y_sel = 2'd0;
            end else if (y_cnt == center_y[i] + sample_dy) begin
                y_hit = 1'b1;
                sample_y = i[3:0];
                y_sel = 2'd2;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mode <= M_DETECT;
            det_min_x <= 14'h3FFF;
            det_max_x <= 14'd0;
            det_min_y <= 14'h3FFF;
            det_max_y <= 14'd0;
            det_count <= 16'd0;
            run_active <= 1'b0;
            run_soft_blue_only <= 1'b0;
            run_start_x <= 14'd0;
            run_len <= 14'd0;
            cand_valid <= 1'b0;
            cand_x0 <= 14'd0;
            cand_x1 <= 14'd0;
            cand_y0 <= 14'd0;
            cand_y1 <= 14'd0;
            sample_dx <= 14'd0;
            sample_dy <= 14'd0;
            calc_busy <= 1'b0;
            calc_idx <= 5'd0;
            calc_acc_x <= 16'd0;
            calc_acc_y <= 16'd0;
            calc_w <= 14'd0;
            calc_h <= 14'd0;
            eval_class <= 3'd0;
            eval_idx <= 8'd0;
            eval_dist <= 8'd0;
            best_dist <= 9'h1FF;
            second_dist <= 9'h1FF;
            best_class <= 3'd0;
            dist_class3 <= 9'h1FF;
            dist_class4 <= 9'h1FF;
            circle_black_hits <= 9'd0;
            eval_ph <= 2'd0;
            eval_mismatch_r <= 1'b0;
            last_class <= 3'd0;
            last_valid <= 1'b0;
            stable_count <= 2'd0;
            cand_red_count <= 16'd0;
            cand_blue_count <= 16'd0;
            cand_yellow_count <= 16'd0;
            cand_black_count <= 16'd0;
            cand_area <= 28'd0;
            cand_parking_direct <= 1'b0;
            parking_run_active <= 1'b0;
            parking_run_start <= 14'd0;
            parking_run_len <= 14'd0;
            parking_pixel_count <= 16'd0;
            parking_total_count <= 16'd0;
            parking_live_valid <= 1'b0;
            parking_min_x <= 14'h3FFF;
            parking_max_x <= 14'd0;
            parking_min_y <= 14'h3FFF;
            parking_max_y <= 14'd0;
            parking_total_min_x <= 14'h3FFF;
            parking_total_max_x <= 14'd0;
            parking_total_min_y <= 14'h3FFF;
            parking_total_max_y <= 14'd0;
            zone_x1 <= 14'd0;
            zone_x2 <= 14'd0;
            zone_y1 <= 14'd0;
            zone_y2 <= 14'd0;
            icon_class <= 3'd0;
            icon_valid <= 1'b0;
            for (i = 0; i < 16; i = i + 1) begin
                center_x[i] <= 14'd0;
                center_y[i] <= 14'd0;
            end
            for (i = 0; i < 15; i = i + 1) begin
                bound_x[i] <= 14'd0;
                bound_y[i] <= 14'd0;
            end
            red_cells <= 256'd0;
            blue_cells <= 256'd0;
            yellow_cells <= 256'd0;
            black_cells <= 256'd0;
            white_cells <= 256'd0;
            for (i = 0; i < 256; i = i + 1) begin
                samples_c[i] <= 3'd0;
                samples_l[i] <= 3'd0;
                samples_r[i] <= 3'd0;
                samples_u[i] <= 3'd0;
                samples_d[i] <= 3'd0;
            end
            for (i = 0; i < 9; i = i + 1)
                black_zone[i] <= 16'd0;
        end else begin
            if (vsync_rise && (mode == M_DETECT)) begin
                det_min_x <= 14'h3FFF;
                det_max_x <= 14'd0;
                det_min_y <= 14'h3FFF;
                det_max_y <= 14'd0;
                det_count <= 16'd0;
                run_active <= 1'b0;
                run_soft_blue_only <= 1'b0;
                parking_run_active <= 1'b0;
                parking_run_len <= 14'd0;
                parking_pixel_count <= 16'd0;
                parking_min_x <= 14'h3FFF;
                parking_max_x <= 14'd0;
                parking_min_y <= 14'h3FFF;
                parking_max_y <= 14'd0;
                parking_total_min_x <= 14'h3FFF;
                parking_total_max_x <= 14'd0;
                parking_total_min_y <= 14'h3FFF;
                parking_total_max_y <= 14'd0;
            end
            if (vsync_rise)
                parking_total_count <= 16'd0;

            // A colour run must be at least 8 pixels long before it can be
            // used for the candidate box.  This removes isolated noise hits
            // and single-pixel colour fringes, which would otherwise stretch
            // the box to the edge of the ROI.
            if (mode == M_DETECT) begin
                if (per_frame_href && border_pix) begin
                    if (!run_active) begin
                        run_active <= 1'b1;
                        run_soft_blue_only <= soft_blue_pix &&
                                              !(red_pix || blue_pix);
                        run_start_x <= x_cnt;
                        run_len <= 14'd1;
                    end else begin
                        if (red_pix || blue_pix)
                            run_soft_blue_only <= 1'b0;
                        if (run_len != 14'h3FFF)
                            run_len <= run_len + 1'b1;
                    end
                end else if (run_active) begin
                    begin : close_run
                        reg [13:0] run_end_x;
                        run_end_x = per_frame_href ? (x_cnt - 1'b1) : x_cnt;
                        run_active <= 1'b0;
                        if (run_len >= (run_soft_blue_only ? 14'd24 : 14'd8)) begin
                            if (det_count <= (16'hFFFF - run_len))
                                det_count <= det_count + run_len;
                            if (run_start_x < det_min_x) det_min_x <= run_start_x;
                            if (run_end_x > det_max_x) det_max_x <= run_end_x;
                            if (y_cnt < det_min_y) det_min_y <= y_cnt;
                            if (y_cnt > det_max_y) det_max_y <= y_cnt;
                        end
                    end
                end

                // Independent parking detector.  Short blue flecks are
                // discarded; only 24-pixel horizontal runs contribute to the
                // parking region.  This path does not depend on det_count or
                // cand_valid from the generic red/blue candidate detector.
                if (per_frame_href && parking_blue_pix) begin
                    if (!parking_run_active) begin
                        parking_run_active <= 1'b1;
                        parking_run_start <= x_cnt;
                        parking_run_len <= 14'd1;
                    end else if (parking_run_len != 14'h3FFF)
                        parking_run_len <= parking_run_len + 1'b1;
                end else if (parking_run_active) begin
                    begin : close_parking_run
                        reg [13:0] parking_run_end;
                        parking_run_end =
                            per_frame_href ? (x_cnt - 1'b1) : x_cnt;
                        parking_run_active <= 1'b0;
                        if (parking_run_len >= 14'd48) begin
                            if (parking_pixel_count <=
                                (16'hFFFF - parking_run_len))
                                parking_pixel_count <=
                                    parking_pixel_count + parking_run_len;
                            if (parking_run_start < parking_min_x)
                                parking_min_x <= parking_run_start;
                            if (parking_run_end > parking_max_x)
                                parking_max_x <= parking_run_end;
                            if (y_cnt < parking_min_y)
                                parking_min_y <= y_cnt;
                            if (y_cnt > parking_max_y)
                                parking_max_y <= y_cnt;
                        end
                    end
                end
            end

            // Frame-level fallback: a parking sign occupies a large part of
            // the central ROI even after the generic box or run filter gives
            // up.  Count all tolerant blue pixels in the ROI and latch a
            // direct parking result at the end of the frame.
            if (in_roi && parking_blue_pix &&
                (parking_total_count != 16'hFFFF))
                parking_total_count <= parking_total_count + 1'b1;
            if (in_roi && parking_blue_pix) begin
                if (x_cnt < parking_total_min_x)
                    parking_total_min_x <= x_cnt;
                if (x_cnt > parking_total_max_x)
                    parking_total_max_x <= x_cnt;
                if (y_cnt < parking_total_min_y)
                    parking_total_min_y <= y_cnt;
                if (y_cnt > parking_total_max_y)
                    parking_total_max_y <= y_cnt;
            end

            if (mode == M_SAMPLE && cand_valid &&
                per_frame_href && per_frame_vsync &&
                (x_cnt >= cand_x0) && (x_cnt <= cand_x1) &&
                (y_cnt >= cand_y0) && (y_cnt <= cand_y1)) begin
                if (red_pix && (cand_red_count != 16'hFFFF))
                    cand_red_count <= cand_red_count + 1'b1;
                if ((blue_pix || soft_blue_pix) &&
                    (cand_blue_count != 16'hFFFF))
                    cand_blue_count <= cand_blue_count + 1'b1;
                if (yellow_pix && (cand_yellow_count != 16'hFFFF))
                    cand_yellow_count <= cand_yellow_count + 1'b1;
                if (black_pix) begin
                    begin : count_black_zone
                        reg [1:0] zx, zy;
                        reg [3:0] zi;
                        zx = (x_cnt < zone_x1) ? 2'd0 :
                             (x_cnt < zone_x2) ? 2'd1 : 2'd2;
                        zy = (y_cnt < zone_y1) ? 2'd0 :
                             (y_cnt < zone_y2) ? 2'd1 : 2'd2;
                        zi = {zy, 1'b0} + zy + zx;
                        if (black_zone[zi] != 16'hFFFF)
                            black_zone[zi] <= black_zone[zi] + 1'b1;
                    end
                    if (cand_black_count != 16'hFFFF)
                        cand_black_count <= cand_black_count + 1'b1;
                end
            end

            if (mode == M_SAMPLE && cand_valid &&
                per_frame_href && per_frame_vsync && x_hit && y_hit) begin
                if ((x_sel == 2'd1) && (y_sel == 2'd1))
                    samples_c[{sample_y, sample_x}] <= sample_cat;
                else if ((x_sel == 2'd0) && (y_sel == 2'd1))
                    samples_l[{sample_y, sample_x}] <= sample_cat;
                else if ((x_sel == 2'd2) && (y_sel == 2'd1))
                    samples_r[{sample_y, sample_x}] <= sample_cat;
                else if ((x_sel == 2'd1) && (y_sel == 2'd0))
                    samples_u[{sample_y, sample_x}] <= sample_cat;
                else if ((x_sel == 2'd1) && (y_sel == 2'd2))
                    samples_d[{sample_y, sample_x}] <= sample_cat;
            end

            if (vsync_fall) begin
                // The parking recognition can come from the whole-ROI area
                // vote.  Keep the visible box on the same total-blue bbox
                // instead of the unrelated generic red/blue candidate.
                if (parking_total_box_ready) begin
                    cand_valid <= 1'b1;
                    cand_parking_direct <= 1'b1;
                    cand_x0 <= parking_total_min_x;
                    cand_x1 <= parking_total_max_x;
                    cand_y0 <= parking_total_min_y;
                    cand_y1 <= parking_total_max_y;
                end
                if ((parking_total_count >= 16'd1500) &&
                    (parking_total_count >= active_roi_dense_w) &&
                    (parking_total_count >= active_roi_dense_h)) begin
                    parking_live_valid <= 1'b1;
                    icon_class <= 3'd5;
                    icon_valid <= 1'b1;
                end else begin
                    parking_live_valid <= 1'b0;
                end
                if (mode == M_DETECT) begin
                    begin : make_candidate
                        reg [13:0] cw, ch;
                        reg [13:0] det_cw, det_ch;
                        reg [13:0] box_x0, box_x1, box_y0, box_y1;
                        reg [13:0] thirdx, thirdy;
                        reg regular_valid, parking_here;
                        det_cw = (det_max_x >= det_min_x) ?
                             (det_max_x - det_min_x + 1'b1) : 14'd0;
                        det_ch = (det_max_y >= det_min_y) ?
                             (det_max_y - det_min_y + 1'b1) : 14'd0;
                        regular_valid = (det_count >= 16'd72) &&
                                        (det_cw >= 14'd56) &&
                                        (det_ch >= 14'd56) &&
                                        (det_cw <= 14'd1000) &&
                                        (det_ch <= 14'd1000) &&
                                        ({14'd0, det_cw} <=
                                         ({14'd0, det_ch} << 1)) &&
                                        ({14'd0, det_ch} <=
                                         ({14'd0, det_cw} << 1)) &&
                                        (det_min_x > roi_x0) &&
                                        (det_max_x < roi_x1) &&
                                        (det_min_y > roi_y0) &&
                                        (det_max_y < roi_y1);
                        parking_here = parking_region_valid ||
                                       parking_total_box_ready;
                        if (parking_here) begin
                            if (parking_region_valid) begin
                                box_x0 = parking_min_x;
                                box_x1 = parking_max_x;
                                box_y0 = parking_min_y;
                                box_y1 = parking_max_y;
                            end else begin
                                box_x0 = parking_total_min_x;
                                box_x1 = parking_total_max_x;
                                box_y0 = parking_total_min_y;
                                box_y1 = parking_total_max_y;
                            end
                        end else begin
                            box_x0 = det_min_x;
                            box_x1 = det_max_x;
                            box_y0 = det_min_y;
                            box_y1 = det_max_y;
                        end
                        cw = (box_x1 >= box_x0) ?
                             (box_x1 - box_x0 + 1'b1) : 14'd0;
                        ch = (box_y1 >= box_y0) ?
                             (box_y1 - box_y0 + 1'b1) : 14'd0;
                        cand_valid <= regular_valid || parking_here;
                        cand_parking_direct <= parking_here;
                        cand_x0 <= box_x0;
                        cand_x1 <= box_x1;
                        cand_y0 <= box_y0;
                        cand_y1 <= box_y1;
                        cand_area <= ({14'd0, cw} * {14'd0, ch});
                        thirdx = (cw * 16'd21846) >> 16;
                        thirdy = (ch * 16'd21846) >> 16;
                        // Majority-vote probe offset: one 16th of a cell.
                        sample_dx <= (cw >> 6) ? (cw >> 6) : 14'd1;
                        sample_dy <= (ch >> 6) ? (ch >> 6) : 14'd1;
                        zone_x1 <= box_x0 + thirdx;
                        zone_x2 <= box_x1 - thirdx;
                        zone_y1 <= box_y0 + thirdy;
                        zone_y2 <= box_y1 - thirdy;
                        cand_red_count <= 16'd0;
                        cand_blue_count <= 16'd0;
                        cand_yellow_count <= 16'd0;
                        cand_black_count <= 16'd0;
                        for (j = 0; j < 9; j = j + 1)
                            black_zone[j] <= 16'd0;
                        // Exact 16-band centres: x0 + w*(2i+1)/32.
                        // They are generated sequentially in 16 cycles,
                        // which is free inside vertical blanking.
                        calc_w <= cw;
                        calc_h <= ch;
                        calc_acc_x <= {2'b00, cw};
                        calc_acc_y <= {2'b00, ch};
                        calc_idx <= 5'd0;
                        calc_busy <= 1'b1;
                    end
                    mode <= M_SAMPLE;
                    // Keep the previous class/valid until the new evaluation
                    // finishes, otherwise the box and the Chinese label blink
                    // at half the frame rate.
                end else if (mode == M_SAMPLE) begin
                    if (cand_valid) begin
                        eval_class <= 3'd0;
                        eval_idx <= 8'd0;
                        eval_dist <= 9'd0;
                        best_dist <= 9'h1FF;
                        second_dist <= 9'h1FF;
                        best_class <= 3'd0;
                        circle_black_hits <= 9'd0;
                        eval_ph <= 2'd0;
                        eval_mismatch_r <= 1'b0;
                        mode <= M_EVAL;
                    end else begin
                        // Nothing was detected: drop the stale result instead
                        // of re-scoring last frame's samples.
                        icon_valid <= 1'b0;
                        last_valid <= 1'b0;
                        stable_count <= 2'd0;
                        mode <= M_DETECT;
                    end
                end
            end

            if (calc_busy) begin
                center_x[calc_idx[3:0]] <= cand_x0 + (calc_acc_x >> 5);
                center_y[calc_idx[3:0]] <= cand_y0 + (calc_acc_y >> 5);
                if (calc_idx != 5'd15) begin
                    bound_x[calc_idx[3:0]] <=
                        cand_x0 + ((calc_acc_x + {2'b00, calc_w}) >> 5);
                    bound_y[calc_idx[3:0]] <=
                        cand_y0 + ((calc_acc_y + {2'b00, calc_h}) >> 5);
                end
                calc_acc_x <= calc_acc_x + {1'b0, calc_w, 1'b0};
                calc_acc_y <= calc_acc_y + {1'b0, calc_h, 1'b0};
                if (calc_idx == 5'd15)
                    calc_busy <= 1'b0;
                else
                    calc_idx <= calc_idx + 1'b1;
            end

            if (mode == M_EVAL) begin
                case (eval_ph)
                    2'd0: begin
                        // Phase 0: address the arrays, register the word.
                        eval_word_r <= {samples_c[eval_idx], samples_l[eval_idx],
                                        samples_r[eval_idx], samples_u[eval_idx],
                                        samples_d[eval_idx]};
                        eval_tmpl_r <= template_mem[{eval_class, eval_idx}];
                        eval_ph <= 2'd1;
                    end
                    2'd1: begin
                        // Phase 1: majority vote + compare.
                        eval_mismatch_r <= (cell_category != eval_tmpl_r);
                        // The two circular signs have the same red outline.
                        // Their real discriminator is the centre: no-entry
                        // has a white bar, while speed-limit 30 has black
                        // digits.  Count actual black cells once while the
                        // class-3 template pass is already reading the grid.
                        if ((eval_class == 3'd3) &&
                            (cell_category == 3'd1) &&
                            (circle_black_hits != 9'h1FF))
                            circle_black_hits <= circle_black_hits + 1'b1;
                        eval_ph <= 2'd2;
                    end
                    default: begin
                        // Phase 2: accumulate / close the class.
                        eval_ph <= 2'd0;
                        if (eval_idx == 8'd255) begin
                            begin : finish_class
                                reg [8:0] dist_final;
                                reg [8:0] win_dist;
                                reg [2:0] win_class;
                                reg [8:0] pair_dist;
                                reg [2:0] pair_class;
                                reg       pair_forced;
                                dist_final = eval_dist + {8'd0, eval_mismatch_r};
                                if (eval_class == 3'd3)
                                    dist_class3 <= dist_final;
                                else if (eval_class == 3'd4)
                                    dist_class4 <= dist_final;
                                win_dist = best_dist;
                                win_class = best_class;
                                pair_dist = best_dist;
                                pair_class = best_class;
                                pair_forced = 1'b0;
                                // If either circle wins the generic template
                                // comparison, use its centre content to break
                                // the 3/4 tie.  The normal template margin is
                                // intentionally bypassed only in this narrow
                                // pair and only when the centre evidence is
                                // decisive.
                                if ((best_class == 3'd3) ||
                                    (best_class == 3'd4)) begin
                                    if (circle_black_hits <= 9'd2) begin
                                        pair_class = 3'd3;
                                        pair_dist = dist_class3;
                                        pair_forced = 1'b1;
                                    end else if (circle_black_hits >= 9'd7) begin
                                        pair_class = 3'd4;
                                        pair_dist = dist_class4;
                                        pair_forced = 1'b1;
                                    end
                                    if (pair_forced) begin
                                        win_class = pair_class;
                                        win_dist = pair_dist;
                                    end
                                end
                                if (eval_class == 3'd5) begin
                                    // The parking sign is the only card with a
                                    // large contiguous blue field.  The
                                    // template still handles the other five
                                    // classes exactly as before; this vote is
                                    // a parking-only fallback for weak blue.
                                    if (cand_parking_direct ||
                                        ((cand_area != 28'd0) &&
                                        ({10'd0, cand_blue_count, 2'b00} >=
                                         cand_area))) begin
                                        win_dist = 9'd0;
                                        win_class = 3'd5;
                                    end else begin
                                        // Class 5 is parking only. Never let the
                                        // parking template win from generic
                                        // template distance alone.
                                        win_dist = best_dist;
                                        win_class = best_class;
                                    end
                                    if (cand_parking_direct) begin
                                        // The independent blue-region detector
                                        // is the parking class decision, so do
                                        // not require a template distance or a
                                        // three-frame generic voting delay.
                                        last_class <= 3'd5;
                                        last_valid <= 1'b1;
                                        stable_count <= 2'd3;
                                        icon_class <= 3'd5;
                                        icon_valid <= 1'b1;
                                    end else if ((pair_forced &&
                                                  (win_dist <=
                                                   ({1'b0, MAX_TEMPLATE_DISTANCE} +
                                                    9'd16))) ||
                                                 (!pair_forced &&
                                                  (win_dist <=
                                                   {1'b0, MAX_TEMPLATE_DISTANCE}) &&
                                                  (win_dist + BEST_CLASS_MARGIN <=
                                                   second_dist))) begin
                                        if (last_valid && (last_class == win_class)) begin
                                            if (stable_count != 2'd3)
                                                stable_count <= stable_count + 1'b1;
                                            if (stable_count >= 2'd1) begin
                                                icon_class <= win_class;
                                                icon_valid <= 1'b1;
                                            end else begin
                                                icon_valid <= 1'b0;
                                            end
                                        end else begin
                                            last_class <= win_class;
                                            last_valid <= 1'b1;
                                            stable_count <= 2'd0;
                                            icon_valid <= 1'b0;
                                        end
                                    end else begin
                                        last_valid <= 1'b0;
                                        stable_count <= 2'd0;
                                        icon_valid <= 1'b0;
                                    end
                                    mode <= M_DETECT;
                                end else begin
                                    if (dist_final < best_dist) begin
                                        second_dist <= best_dist;
                                        best_dist <= dist_final;
                                        best_class <= eval_class;
                                    end else if (dist_final < second_dist) begin
                                        second_dist <= dist_final;
                                    end
                                    eval_class <= eval_class + 1'b1;
                                    eval_idx <= 8'd0;
                                    eval_dist <= 9'd0;
                                end
                            end
                        end else begin
                            eval_idx <= eval_idx + 1'b1;
                            eval_dist <= eval_dist + {8'd0, eval_mismatch_r};
                        end
                    end
                endcase
            end

            // Keep the parking result authoritative over generic template
            // state and the normal three-frame voting delay.
            if (parking_live_valid) begin
                last_class <= 3'd5;
                last_valid <= 1'b1;
                stable_count <= 2'd3;
                icon_class <= 3'd5;
                icon_valid <= 1'b1;
            end
        end
    end

    reg [7:0] d1_r, d1_g, d1_b;
    reg d1_vsync, d1_href, d1_hsync;
    reg [13:0] d1_x, d1_y;

    wire guide_on =
        (d1_x + 2 >= roi_x0) && (d1_x <= roi_x1 + 2) &&
        (d1_y + 2 >= roi_y0) && (d1_y <= roi_y1 + 2) &&
        ((d1_x < roi_x0 + 2) || (d1_x > roi_x1 - 2) ||
         (d1_y < roi_y0 + 2) || (d1_y > roi_y1 - 2));

    wire box_on = cand_valid &&
                  (d1_x >= cand_x0) && (d1_x <= cand_x1) &&
                  (d1_y >= cand_y0) && (d1_y <= cand_y1) &&
                  ((d1_x <= cand_x0 + 2) || (d1_x + 2 >= cand_x1) ||
                   (d1_y <= cand_y0 + 2) || (d1_y + 2 >= cand_y1));

    wire d_in_roi = (d1_x >= roi_x0) && (d1_x <= roi_x1) &&
                    (d1_y >= roi_y0) && (d1_y <= roi_y1);
    wire d_red = d_in_roi && (d1_r >= 8'd95) &&
                 (d1_r > d1_g + 8'd20) && (d1_r > d1_b + 8'd20);
    wire d_blue = d_in_roi && (d1_b >= 8'd80) &&
                  (d1_b > d1_r + 8'd25) && (d1_b > d1_g + 8'd20);
    wire d_yellow = d_in_roi && (d1_r >= 8'd100) &&
                    (d1_g >= 8'd85) &&
                    (d1_r > d1_b + 8'd30) && (d1_g > d1_b + 8'd25);
    wire d_black = d_in_roi && (d1_r <= 8'd110) &&
                   (d1_g <= 8'd110) && (d1_b <= 8'd110) &&
                   ((d1_r > d1_g ? d1_r - d1_g : d1_g - d1_r) < 8'd32) &&
                   ((d1_g > d1_b ? d1_g - d1_b : d1_b - d1_g) < 8'd32);
    wire d_in_candidate = cand_valid &&
                          (d1_x >= cand_x0) && (d1_x <= cand_x1) &&
                          (d1_y >= cand_y0) && (d1_y <= cand_y1);
    wire d_candidate_black = d_black && d_in_candidate;

    reg [3:0] sig_cell_x, sig_cell_y;
    integer k;
    always @(*) begin
        sig_cell_x = 4'd15;
        sig_cell_y = 4'd15;
        for (k = 0; k < 15; k = k + 1) begin
            if (d1_x < bound_x[k])
                sig_cell_x = k[3:0];
            if (d1_y < bound_y[k])
                sig_cell_y = k[3:0];
        end
    end
    wire [2:0] sig_category = samples_c[{sig_cell_y, sig_cell_x}];
    reg sig_grid_line;
    integer k2;
    always @(*) begin
        sig_grid_line = 1'b0;
        for (k2 = 0; k2 < 15; k2 = k2 + 1) begin
            if ((d1_x == bound_x[k2]) || (d1_y == bound_y[k2]))
                sig_grid_line = 1'b1;
        end
    end

    reg [7:0] box_r, box_g, box_b;
    reg [7:0] diag_r, diag_g, diag_b;
    always @(*) begin
        diag_r = 8'h00; diag_g = 8'h00; diag_b = 8'h00;
        case (cfg_diag_mode)
            3'd1: begin
                // Raw colour inside the ROI; outside is deliberately dim.
                if (d_in_roi) begin
                    diag_r = d1_r; diag_g = d1_g; diag_b = d1_b;
                end else begin
                    diag_r = 8'h18; diag_g = 8'h18; diag_b = 8'h18;
                end
                if (box_on) begin diag_r = 8'hFF; diag_g = 8'h00; diag_b = 8'hFF; end
                if (guide_on) begin diag_r = 8'h00; diag_g = 8'hFF; diag_b = 8'hFF; end
            end
            3'd2: begin
                // Five-colour segmentation.  Neutral/white paper is grey,
                // never white, so it cannot hide the candidate outline.
                diag_r = 8'h28; diag_g = 8'h28; diag_b = 8'h28;
                if (d_red) begin diag_r = 8'hFF; diag_g = 8'h00; diag_b = 8'h00; end
                else if (d_blue) begin diag_r = 8'h00; diag_g = 8'h00; diag_b = 8'hFF; end
                else if (d_yellow) begin diag_r = 8'hFF; diag_g = 8'hFF; diag_b = 8'h00; end
                else if (d_black) begin diag_r = 8'h00; diag_g = 8'h00; diag_b = 8'h00; end
                else if (d_in_roi) begin
                    diag_r = 8'h88; diag_g = 8'h88; diag_b = 8'h88;
                end
                if (box_on) begin diag_r = 8'hFF; diag_g = 8'h00; diag_b = 8'hFF; end
                if (guide_on) begin diag_r = 8'h00; diag_g = 8'hFF; diag_b = 8'hFF; end
            end
            3'd3: begin
                // Only the black mask inside a valid candidate is shown.
                diag_r = 8'h00; diag_g = 8'h00; diag_b = 8'h00;
                if (d_candidate_black) begin diag_r = 8'hFF; diag_g = 8'hFF; diag_b = 8'hFF; end
                if (box_on) begin diag_r = 8'hFF; diag_g = 8'h00; diag_b = 8'hFF; end
                if (guide_on) begin diag_r = 8'h00; diag_g = 8'hFF; diag_b = 8'hFF; end
            end
            3'd4: begin
                // Reconstructed 16x16 classification signature.  This is
                // the exact data seen by the six-template matcher.
                diag_r = 8'h18; diag_g = 8'h18; diag_b = 8'h18;
                if (d_in_candidate) begin
                    case (sig_category)
                        3'd0: begin diag_r = 8'hB0; diag_g = 8'hB0; diag_b = 8'hB0; end
                        3'd1: begin diag_r = 8'h00; diag_g = 8'h00; diag_b = 8'h00; end
                        3'd2: begin diag_r = 8'hFF; diag_g = 8'h00; diag_b = 8'h00; end
                        3'd3: begin diag_r = 8'hFF; diag_g = 8'hE0; diag_b = 8'h00; end
                        3'd4: begin diag_r = 8'h00; diag_g = 8'h40; diag_b = 8'hFF; end
                        default: begin diag_r = 8'h40; diag_g = 8'h40; diag_b = 8'h40; end
                    endcase
                    if (sig_grid_line) begin
                        diag_r = 8'h38; diag_g = 8'h38; diag_b = 8'h38;
                    end
                end
                if (box_on) begin diag_r = 8'hFF; diag_g = 8'h00; diag_b = 8'hFF; end
                if (guide_on) begin diag_r = 8'h00; diag_g = 8'hFF; diag_b = 8'hFF; end
            end
            3'd5: begin
                diag_r = d1_r; diag_g = d1_g; diag_b = d1_b;
                if (icon_valid) begin diag_r = box_r; diag_g = box_g; diag_b = box_b; end
            end
            default: begin
                diag_r = d1_r; diag_g = d1_g; diag_b = d1_b;
            end
        endcase
    end

    always @(*) begin
        case (icon_class)
            3'd0: begin box_r = 8'hFF; box_g = 8'h90; box_b = 8'h00; end
            3'd1: begin box_r = 8'h20; box_g = 8'hFF; box_b = 8'h40; end
            3'd2: begin box_r = 8'h00; box_g = 8'hFF; box_b = 8'hFF; end
            3'd3: begin box_r = 8'hFF; box_g = 8'h20; box_b = 8'h20; end
            3'd4: begin box_r = 8'hFF; box_g = 8'h40; box_b = 8'hFF; end
            default: begin box_r = 8'h20; box_g = 8'h80; box_b = 8'hFF; end
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d1_r <= 8'd0; d1_g <= 8'd0; d1_b <= 8'd0;
            d1_vsync <= 1'b0; d1_href <= 1'b0; d1_hsync <= 1'b0;
            d1_x <= 14'd0; d1_y <= 14'd0;
            post_frame_vsync <= 1'b0;
            post_frame_href <= 1'b0;
            post_frame_hsync <= 1'b0;
            post_img_red <= 8'd0;
            post_img_green <= 8'd0;
            post_img_blue <= 8'd0;
        end else begin
            d1_r <= per_img_red;
            d1_g <= per_img_green;
            d1_b <= per_img_blue;
            d1_vsync <= per_frame_vsync;
            d1_href <= per_frame_href;
            d1_hsync <= per_frame_hsync;
            d1_x <= x_cnt;
            d1_y <= y_cnt;

            post_frame_vsync <= d1_vsync;
            post_frame_href <= d1_href;
            post_frame_hsync <= d1_hsync;
            if (cfg_diag_mode != 3'd0) begin
                post_img_red <= diag_r;
                post_img_green <= diag_g;
                post_img_blue <= diag_b;
            end else if (box_on) begin
                if (icon_valid) begin
                    post_img_red <= box_r;
                    post_img_green <= box_g;
                    post_img_blue <= box_b;
                end else begin
                    // Candidate found but no template matched: bright yellow
                    // box (not one of the six class colours), so it is easy to
                    // tell "detected but unknown" from "nothing detected".
                    post_img_red <= 8'hFF;
                    post_img_green <= 8'hE0;
                    post_img_blue <= 8'h00;
                end
            end else if (guide_on) begin
                post_img_red <= 8'h00;
                post_img_green <= 8'h50;
                post_img_blue <= 8'h50;
            end else begin
                post_img_red <= d1_r;
                post_img_green <= d1_g;
                post_img_blue <= d1_b;
            end
        end
    end
endmodule
