`timescale 1ns/1ps

// Camera-motion-guarded palm-entry trigger for task 8.
//
// A size-qualified skin target must remain in the small central ROI for four
// frames.  It must then leave the ROI before another trigger is allowed.
module VIP_HandMotionWave #(
    parameter [13:0] IMG_HDISP = 14'd1920,
    parameter [13:0] IMG_VDISP = 14'd1080,
    parameter [13:0] ROI_X0 = 14'd680,
    parameter [13:0] ROI_X1 = 14'd1239,
    parameter [13:0] ROI_Y0 = 14'd380,
    parameter [13:0] ROI_Y1 = 14'd699,
    parameter [11:0] MIN_TOTAL_SAMPLES = 12'd24,
    parameter [11:0] MIN_PEAK_SAMPLES = 12'd10,
    parameter [11:0] MIN_PEAK_GAP = 12'd1,
    parameter [11:0] MAX_MOTION_SAMPLES = 12'd1500,
    parameter [11:0] MIN_GUARD_SAMPLES = 12'd128,
    parameter [17:0] MIN_SKIN_AREA = 18'd4000,
    parameter [17:0] MAX_SKIN_AREA = 18'd170000,
    parameter [13:0] MIN_BLOB_W = 14'd50,
    parameter [13:0] MAX_BLOB_W = 14'd520,
    parameter [13:0] MIN_BLOB_H = 14'd50,
    parameter [13:0] MAX_BLOB_H = 14'd300,
    parameter [7:0]  MOTION_THRESHOLD = 8'd18,
    parameter [7:0]  STAGE_TIMEOUT_FRAMES = 8'd60,
    parameter [7:0]  COOLDOWN_FRAMES = 8'd20,
    parameter [3:0]  PALM_STABLE_FRAMES = 4'd4,
    parameter [3:0]  PALM_REARM_FRAMES = 4'd12
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        per_frame_vsync,
    input  wire        per_frame_href,
    input  wire        per_frame_hsync,
    input  wire [7:0]  per_img_red,
    input  wire [7:0]  per_img_green,
    input  wire [7:0]  per_img_blue,

    output reg         gesture_toggle,
    output wire        motion_active,
    output wire        roi_motion_active,
    output wire        camera_motion_active,
    output reg  [11:0] motion_peak
);

    reg [13:0] x_cnt, y_cnt;
    reg href_d, vsync_d;
    wire href_rise = per_frame_href && !href_d;
    wire vsync_rise = per_frame_vsync && !vsync_d;

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

    // ---------------------------------------------------------------
    // Sparse ROI and background-guard sampling
    // ---------------------------------------------------------------
    wire in_roi = per_frame_vsync && per_frame_href &&
                  (x_cnt >= ROI_X0) && (x_cnt <= ROI_X1) &&
                  (y_cnt >= ROI_Y0) && (y_cnt <= ROI_Y1);
    wire [13:0] rel_x = x_cnt - ROI_X0;
    wire [13:0] rel_y = y_cnt - ROI_Y0;
    wire roi_sample_point = in_roi && (rel_x[3:0] == 4'd0) &&
                            (rel_y[3:0] == 4'd0);
    wire [5:0] sample_x = rel_x[9:4];
    wire [5:0] sample_y = rel_y[9:4];
    wire [11:0] sample_addr = {sample_y, sample_x};
    wire [1:0] sample_bin = sample_x[5:4];

    wire guard_left = (x_cnt >= 14'd64) && (x_cnt <= 14'd479);
    wire guard_right = (x_cnt >= 14'd1568) && (x_cnt <= 14'd1919);
    wire guard_band = (y_cnt >= 14'd160) && (y_cnt <= 14'd927);
    wire [13:0] guard_rel_x = guard_right ?
                              (x_cnt - 14'd1568) :
                              (x_cnt - 14'd64);
    wire [13:0] guard_rel_y = y_cnt - 14'd160;
    wire guard_sample_point =
        per_frame_vsync && per_frame_href && guard_band &&
        (guard_left || guard_right) &&
        (guard_rel_x[4:0] == 5'd0) &&
        (guard_rel_y[4:0] == 5'd0);
    wire [4:0] guard_x_idx = guard_rel_x[8:5];
    wire [4:0] guard_y_idx = guard_rel_y[9:5];
    wire [9:0] guard_row_base = {guard_y_idx, 4'b0000};
    wire [9:0] guard_linear_10 =
        guard_row_base + {6'd0, guard_x_idx} +
        (guard_right ? 10'd384 : 10'd0);
    wire [10:0] guard_linear = {1'b0, guard_linear_10};
    wire [11:0] guard_addr = 12'd2304 + guard_linear;

    wire mem_sample_point = roi_sample_point || guard_sample_point;
    wire [11:0] mem_sample_addr = roi_sample_point ?
                                  sample_addr : guard_addr;

    wire [9:0] luma_sum =
        {2'b00, per_img_red} + {1'b0, per_img_green, 1'b0} +
        {2'b00, per_img_blue};
    wire [7:0] luma = luma_sum[9:2];

    wire [7:0] rg_max = (per_img_red > per_img_green) ?
                        per_img_red : per_img_green;
    wire [7:0] rg_min = (per_img_red < per_img_green) ?
                        per_img_red : per_img_green;
    wire [7:0] pix_max = (rg_max > per_img_blue) ?
                         rg_max : per_img_blue;
    wire [7:0] pix_min = (rg_min < per_img_blue) ?
                         rg_min : per_img_blue;
    wire [7:0] pix_chroma = pix_max - pix_min;
    wire skin_pixel =
        (per_img_red >= 8'd42) && (per_img_red <= 8'd253) &&
        (pix_chroma >= 8'd8) &&
        (per_img_red >= per_img_green + 8'd3) &&
        (per_img_red >= per_img_blue + 8'd6) &&
        (per_img_green + 8'd18 >= per_img_blue);

    // Ping-pong RAM banks: current frame to one bank, previous from the other.
    reg [11:0] sample_addr_q;
    reg [7:0] sample_luma_q;
    reg [7:0] current_luma_q;
    reg sample_req;
    reg sample_req_d;
    reg sample_is_roi_q;
    reg skin_sample_q;
    reg [1:0] sample_bin_q;
    reg bank_sel;
    (* syn_ramstyle = "block" *) reg [7:0] frame_ram0 [0:4095];
    (* syn_ramstyle = "block" *) reg [7:0] frame_ram1 [0:4095];
    reg [7:0] bank0_luma;
    reg [7:0] bank1_luma;
    wire [7:0] previous_ram_luma = bank_sel ? bank0_luma : bank1_luma;

    // Four thousand ninety-six bytes cover the ROI and both background
    // guard bands. The previous EFX_RAM10 instances exposed only 10 address
    // bits, so the computed 12-bit addresses wrapped and overwrote entries.
    always @(posedge clk) begin
        if (sample_req && !bank_sel)
            frame_ram0[sample_addr_q] <= sample_luma_q;
        if (sample_req && bank_sel)
            frame_ram1[sample_addr_q] <= sample_luma_q;
        bank0_luma <= frame_ram0[sample_addr_q];
        bank1_luma <= frame_ram1[sample_addr_q];
    end

    // ---------------------------------------------------------------
    // Per-frame statistics
    // ---------------------------------------------------------------
    reg sample_valid_q;
    reg [2:0] settle_frames;
    reg [11:0] roi_motion_count;
    reg [11:0] skin_motion_count;
    reg [11:0] guard_motion_count;
    reg [17:0] skin_area_count;
    reg [13:0] skin_min_x, skin_max_x;
    reg [13:0] skin_min_y, skin_max_y;
    reg [17:0] frame_skin_area_q;
    reg [13:0] frame_skin_min_x_q, frame_skin_max_x_q;
    reg [13:0] frame_skin_min_y_q, frame_skin_max_y_q;
    (* syn_ramstyle = "registers" *) reg [11:0] bin_count [0:3];
    reg [11:0] peak_count;
    reg [11:0] second_count;
    reg [1:0] peak_bin;
    reg [2:0] motion_score;
    reg [2:0] roi_motion_score;
    reg [2:0] camera_motion_score;
    reg [5:0] peak_hold_frames;
    reg [7:0] cooldown_frames;
    reg [7:0] stage_age;
    reg [1:0] swipe_phase;
    reg       swipe_dir;
    reg [3:0] palm_stable_count;
    reg [3:0] palm_absent_count;
    reg       palm_armed;
    reg       bin_scan_active;
    reg [2:0] bin_scan_idx;
    reg [11:0] frame_total_q;
    reg [11:0] frame_roi_total_q;
    reg [11:0] frame_guard_total_q;
    reg        camera_motion_q;
    integer bi;

    wire [7:0] luma_diff =
        (current_luma_q >= previous_ram_luma) ?
        (current_luma_q - previous_ram_luma) :
        (previous_ram_luma - current_luma_q);
    wire motion_sample = sample_valid_q &&
                         (settle_frames >= 3'd7) &&
                         (luma_diff >= MOTION_THRESHOLD);
    wire roi_motion_sample = motion_sample && sample_is_roi_q;
    wire skin_motion_sample = roi_motion_sample && skin_sample_q;
    wire guard_motion_sample = motion_sample && !sample_is_roi_q;
    wire [13:0] blob_w =
        (frame_skin_max_x_q >= frame_skin_min_x_q) ?
        (frame_skin_max_x_q - frame_skin_min_x_q + 1'b1) : 14'd0;
    wire [13:0] blob_h =
        (frame_skin_max_y_q >= frame_skin_min_y_q) ?
        (frame_skin_max_y_q - frame_skin_min_y_q + 1'b1) : 14'd0;
    wire [13:0] blob_cx =
        (frame_skin_max_x_q + frame_skin_min_x_q) >> 1;
    wire blob_size_valid =
        (frame_skin_area_q >= MIN_SKIN_AREA) &&
        (frame_skin_area_q <= MAX_SKIN_AREA);
    wire blob_valid = blob_size_valid && !camera_motion_q;
    wire blob_left =
        blob_valid && (blob_cx < (ROI_X0 + 14'd277));
    wire blob_right =
        blob_valid && (blob_cx > (ROI_X1 - 14'd277));

    // Register scan avoids a wide priority tree on the pixel clock.
    wire [11:0] scan_value = bin_count[bin_scan_idx[1:0]];
    wire [11:0] scan_peak_count =
        (scan_value > peak_count) ? scan_value : peak_count;
    wire [11:0] scan_second_count =
        (scan_value > peak_count) ? peak_count :
        ((scan_value > second_count) ? scan_value : second_count);
    wire [1:0] scan_peak_bin =
        (scan_value > peak_count) ? bin_scan_idx[1:0] : peak_bin;
    wire scan_concentrated =
        !camera_motion_q &&
        (frame_total_q >= MIN_TOTAL_SAMPLES) &&
        (frame_total_q <= MAX_MOTION_SAMPLES) &&
        (scan_peak_count >= MIN_PEAK_SAMPLES) &&
        ({1'b0, scan_peak_count} >=
         ({1'b0, scan_second_count} + {1'b0, MIN_PEAK_GAP}));
    wire scan_left = scan_concentrated && (scan_peak_bin == 2'd0);
    wire scan_right = scan_concentrated && (scan_peak_bin == 2'd3);

    assign motion_active = (motion_score != 3'd0);
    assign roi_motion_active = (roi_motion_score != 3'd0);
    assign camera_motion_active = (camera_motion_score != 3'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_addr_q <= 12'd0;
            sample_luma_q <= 8'd0;
            current_luma_q <= 8'd0;
            sample_req <= 1'b0;
            sample_req_d <= 1'b0;
            sample_is_roi_q <= 1'b0;
            skin_sample_q <= 1'b0;
            sample_bin_q <= 2'd0;
            bank_sel <= 1'b0;
            sample_valid_q <= 1'b0;
            settle_frames <= 3'd0;
            roi_motion_count <= 12'd0;
            skin_motion_count <= 12'd0;
            guard_motion_count <= 12'd0;
            skin_area_count <= 18'd0;
            skin_min_x <= 14'h3FFF;
            skin_max_x <= 14'd0;
            skin_min_y <= 14'h3FFF;
            skin_max_y <= 14'd0;
            frame_skin_area_q <= 18'd0;
            frame_skin_min_x_q <= 14'd0;
            frame_skin_max_x_q <= 14'd0;
            frame_skin_min_y_q <= 14'd0;
            frame_skin_max_y_q <= 14'd0;
            motion_score <= 3'd0;
            roi_motion_score <= 3'd0;
            camera_motion_score <= 3'd0;
            peak_hold_frames <= 6'd0;
            cooldown_frames <= 8'd0;
            stage_age <= 8'd0;
            swipe_phase <= 2'd0;
            swipe_dir <= 1'b0;
            palm_stable_count <= 4'd0;
            palm_absent_count <= 4'd0;
            palm_armed <= 1'b0;
            bin_scan_active <= 1'b0;
            bin_scan_idx <= 3'd0;
            frame_total_q <= 12'd0;
            frame_roi_total_q <= 12'd0;
            frame_guard_total_q <= 12'd0;
            camera_motion_q <= 1'b0;
            peak_count <= 12'd0;
            second_count <= 12'd0;
            peak_bin <= 2'd0;
            motion_peak <= 12'd0;
            gesture_toggle <= 1'b0;
            for (bi = 0; bi < 4; bi = bi + 1)
                bin_count[bi] <= 12'd0;
        end else begin
            if (mem_sample_point) begin
                sample_addr_q <= mem_sample_addr;
                sample_luma_q <= luma;
                sample_is_roi_q <= roi_sample_point;
                skin_sample_q <= roi_sample_point && skin_pixel;
                sample_bin_q <= sample_bin;
            end

            sample_req <= mem_sample_point;
            sample_req_d <= sample_req;

            if (sample_req)
                current_luma_q <= sample_luma_q;

            if (sample_req_d)
                sample_valid_q <= 1'b1;
            else
                sample_valid_q <= 1'b0;

            if (roi_motion_sample) begin
                if (roi_motion_count != 12'hFFF)
                    roi_motion_count <= roi_motion_count + 1'b1;
            end

            if (skin_motion_sample) begin
                if (skin_motion_count != 12'hFFF)
                    skin_motion_count <= skin_motion_count + 1'b1;
                if (bin_count[sample_bin_q] != 12'hFFF)
                    bin_count[sample_bin_q] <= bin_count[sample_bin_q] + 1'b1;
            end

            if (guard_motion_sample) begin
                if (guard_motion_count != 12'hFFF)
                    guard_motion_count <= guard_motion_count + 1'b1;
            end

            if (in_roi && skin_pixel) begin
                if (skin_area_count != 18'h3FFFF)
                    skin_area_count <= skin_area_count + 1'b1;
                if (x_cnt < skin_min_x)
                    skin_min_x <= x_cnt;
                if (x_cnt > skin_max_x)
                    skin_max_x <= x_cnt;
                if (y_cnt < skin_min_y)
                    skin_min_y <= y_cnt;
                if (y_cnt > skin_max_y)
                    skin_max_y <= y_cnt;
            end

            if (vsync_rise) begin
                bank_sel <= ~bank_sel;
                frame_total_q <= skin_motion_count;
                frame_roi_total_q <= roi_motion_count;
                frame_guard_total_q <= guard_motion_count;
                frame_skin_area_q <= skin_area_count;
                frame_skin_min_x_q <= skin_min_x;
                frame_skin_max_x_q <= skin_max_x;
                frame_skin_min_y_q <= skin_min_y;
                frame_skin_max_y_q <= skin_max_y;
                camera_motion_q <=
                    (guard_motion_count >= MIN_GUARD_SAMPLES);
                roi_motion_count <= 12'd0;
                skin_motion_count <= 12'd0;
                guard_motion_count <= 12'd0;
                skin_area_count <= 18'd0;
                skin_min_x <= 14'h3FFF;
                skin_max_x <= 14'd0;
                skin_min_y <= 14'h3FFF;
                skin_max_y <= 14'd0;
                bin_scan_active <= 1'b1;
                bin_scan_idx <= 3'd0;
                peak_count <= 12'd0;
                second_count <= 12'd0;
                peak_bin <= 2'd0;

                if (settle_frames != 3'd7)
                    settle_frames <= settle_frames + 1'b1;

                if ((settle_frames >= 3'd7) &&
                    (roi_motion_count > motion_peak)) begin
                    motion_peak <= roi_motion_count;
                    peak_hold_frames <= 6'd60;
                end else if (peak_hold_frames != 6'd0) begin
                    peak_hold_frames <= peak_hold_frames - 1'b1;
                end else if (motion_peak != 12'd0) begin
                    motion_peak <= 12'd0;
                end
            end else if (bin_scan_active) begin
                peak_count <= scan_peak_count;
                second_count <= scan_second_count;
                peak_bin <= scan_peak_bin;

                if (bin_scan_idx == 3'd3) begin
                    bin_scan_active <= 1'b0;
                    bin_scan_idx <= 3'd0;
                    for (bi = 0; bi < 4; bi = bi + 1)
                        bin_count[bi] <= 12'd0;

                    motion_score <= blob_valid ? 3'd7 :
                                    ((motion_score != 3'd0) ?
                                     (motion_score - 1'b1) : 3'd0);
                    roi_motion_score <=
                        (frame_roi_total_q >= MIN_TOTAL_SAMPLES) ? 3'd7 :
                        ((roi_motion_score != 3'd0) ?
                         (roi_motion_score - 1'b1) : 3'd0);
                    camera_motion_score <=
                        (frame_guard_total_q >= MIN_GUARD_SAMPLES) ? 3'd7 :
                        ((camera_motion_score != 3'd0) ?
                         (camera_motion_score - 1'b1) : 3'd0);

                    if (cooldown_frames != 8'd0)
                        cooldown_frames <= cooldown_frames - 1'b1;

                    if (camera_motion_q) begin
                        palm_stable_count <= 4'd0;
                    end else if (blob_valid) begin
                        palm_absent_count <= 4'd0;
                        if (palm_stable_count != PALM_STABLE_FRAMES)
                            palm_stable_count <= palm_stable_count + 1'b1;
                        if (palm_armed && (cooldown_frames == 8'd0) &&
                            (palm_stable_count >=
                             (PALM_STABLE_FRAMES - 1'b1))) begin
                            gesture_toggle <= ~gesture_toggle;
                            palm_armed <= 1'b0;
                            palm_stable_count <= 4'd0;
                            cooldown_frames <= COOLDOWN_FRAMES;
                        end
                    end else begin
                        palm_stable_count <= 4'd0;
                        if (!palm_armed) begin
                            if (palm_absent_count != PALM_REARM_FRAMES)
                                palm_absent_count <= palm_absent_count + 1'b1;
                            if ((palm_absent_count >=
                                 (PALM_REARM_FRAMES - 1'b1)) &&
                                (cooldown_frames == 8'd0))
                                palm_armed <= 1'b1;
                        end
                    end
                end else begin
                    bin_scan_idx <= bin_scan_idx + 1'b1;
                end
            end
        end
    end

endmodule
