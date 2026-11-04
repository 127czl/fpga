`timescale 1ns/1ps

// Live-camera hand gesture side-channel for task 8 playback.
//
// The DDR playback path no longer carries live camera pixels, so this module
// taps the RAW Bayer writer before DDR.  It samples one 2x2 Bayer block from
// every 32-bit writer beat (four pixels), reconstructs an approximate RGB
// value, and measures the largest skin-coloured region in a central ROI.
// One stable palm presentation toggles playback once.
module VIP_HandGestureCtrl #(
    parameter [8:0]  H_WORDS       = 9'd480,
    parameter [9:0]  ROI_X0        = 10'd160,
    parameter [9:0]  ROI_X1        = 10'd319,
    parameter [9:0]  ROI_Y0        = 10'd162,
    parameter [9:0]  ROI_Y1        = 10'd377,
    parameter [15:0] MIN_SKIN_AREA = 16'd500,
    parameter [8:0]  MIN_HAND_W    = 9'd18,
    parameter [8:0]  MIN_HAND_H    = 9'd20,
    parameter [2:0]  STABLE_FRAMES = 3'd7,
    parameter [3:0]  REARM_FRAMES  = 4'd15
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        frame_vsync,
    input  wire        data_en,
    input  wire [31:0] raw_data,

    output reg         gesture_toggle,
    output wire        palm_valid
);

    reg frame_vsync_d;
    wire frame_start = frame_vsync & ~frame_vsync_d;

    reg data_en_d;
    wire line_done = data_en_d & ~data_en;

    reg [8:0] word_cnt;
    reg [9:0] line_cnt;
    reg [7:0] cur_lo_q, cur_hi_q;
    reg [7:0] prev_lo_q, prev_hi_q;
    reg [8:0] sample_x_q;
    reg [9:0] sample_y_q;
    reg       pair_valid_q;

    // Two bytes per 2x2 Bayer block.  The first pair in each 32-bit writer
    // beat is enough for a 480x540 detection image.
    reg [15:0] prev_gb_line [0:479];

    wire [7:0] raw_lo = raw_data[7:0];
    wire [7:0] raw_hi = raw_data[15:8];
    wire line_is_odd = line_cnt[0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_vsync_d <= 1'b0;
            data_en_d <= 1'b0;
            word_cnt <= 9'd0;
            line_cnt <= 10'd0;
            cur_lo_q <= 8'd0;
            cur_hi_q <= 8'd0;
            prev_lo_q <= 8'd0;
            prev_hi_q <= 8'd0;
            sample_x_q <= 9'd0;
            sample_y_q <= 10'd0;
            pair_valid_q <= 1'b0;
        end else begin
            frame_vsync_d <= frame_vsync;
            data_en_d <= data_en;

            if (frame_start) begin
                word_cnt <= 9'd0;
                line_cnt <= 10'd0;
            end else if (data_en) begin
                if (word_cnt == H_WORDS - 1'b1)
                    word_cnt <= 9'd0;
                else
                    word_cnt <= word_cnt + 1'b1;
            end else
                word_cnt <= 9'd0;

            if (!frame_start && line_done) begin
                if (line_cnt == 10'd1079)
                    line_cnt <= 10'd0;
                else
                    line_cnt <= line_cnt + 1'b1;
            end

            // Even Bayer lines in CFA_PATTERN=0 are G/B; odd lines are R/G.
            if (data_en && !line_is_odd)
                prev_gb_line[word_cnt] <= {raw_hi, raw_lo};

            // Synchronous read aligns with the registered current pair in the
            // following clock, so classification runs as a one-cycle pipeline.
            {prev_hi_q, prev_lo_q} <= prev_gb_line[word_cnt];
            cur_lo_q <= raw_lo;
            cur_hi_q <= raw_hi;
            sample_x_q <= word_cnt;
            sample_y_q <= {1'b0, line_cnt[9:1]};
            pair_valid_q <= 1'b0;
            if (data_en && line_is_odd)
                pair_valid_q <= 1'b1;
        end
    end

    function [7:0] max8;
        input [7:0] a;
        input [7:0] b;
        begin
            max8 = (a > b) ? a : b;
        end
    endfunction

    function [7:0] min8;
        input [7:0] a;
        input [7:0] b;
        begin
            min8 = (a < b) ? a : b;
        end
    endfunction

    // Byte order inside the RAW word is intentionally not assumed.  Try both
    // the R/G + G/B and G/B + R/G interpretations and accept either.
    wire [7:0] cur_hi = max8(cur_lo_q, cur_hi_q);
    wire [7:0] cur_lo = min8(cur_lo_q, cur_hi_q);
    wire [7:0] prev_hi = max8(prev_lo_q, prev_hi_q);
    wire [7:0] prev_lo = min8(prev_lo_q, prev_hi_q);
    wire [8:0] green0 = ({1'b0, cur_lo} + {1'b0, prev_hi}) >> 1;
    wire [8:0] green1 = ({1'b0, prev_lo} + {1'b0, cur_hi}) >> 1;

    wire skin0 =
        ({1'b0, cur_hi} >= ({1'b0, green0} + 9'd6)) &&
        ({1'b0, cur_hi} >= ({1'b0, prev_lo} + 9'd12)) &&
        (cur_hi >= 8'd45) && (cur_hi <= 8'd245) &&
        (green0 >= prev_lo);
    wire skin1 =
        ({1'b0, prev_hi} >= ({1'b0, green1} + 9'd6)) &&
        ({1'b0, prev_hi} >= ({1'b0, cur_lo} + 9'd12)) &&
        (prev_hi >= 8'd45) && (prev_hi <= 8'd245) &&
        (green1 >= cur_lo);
    wire skin_sample = pair_valid_q && (skin0 || skin1);

    wire sample_in_roi =
        (sample_x_q >= ROI_X0) && (sample_x_q <= ROI_X1) &&
        (sample_y_q >= ROI_Y0) && (sample_y_q <= ROI_Y1);

    reg [15:0] skin_count;
    reg [8:0] skin_min_x, skin_max_x;
    reg [9:0] skin_min_y, skin_max_y;

    wire [8:0] box_w =
        (skin_max_x >= skin_min_x) ?
        (skin_max_x - skin_min_x + 1'b1) : 9'd0;
    wire [9:0] box_h =
        (skin_max_y >= skin_min_y) ?
        (skin_max_y - skin_min_y + 1'b1) : 10'd0;
    wire frame_candidate =
        (skin_count >= MIN_SKIN_AREA) &&
        (box_w >= MIN_HAND_W) && (box_h >= MIN_HAND_H) &&
        ({1'b0, box_w} <= ({1'b0, box_h} << 2)) &&
        ({1'b0, box_h} <= ({1'b0, box_w} << 2));

    reg [2:0] stable_frames;
    reg [3:0] absent_frames;
    reg       capture_armed;

    assign palm_valid = (stable_frames >= STABLE_FRAMES);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gesture_toggle <= 1'b0;
            skin_count <= 16'd0;
            skin_min_x <= 9'h1FF;
            skin_max_x <= 9'd0;
            skin_min_y <= 10'h3FF;
            skin_max_y <= 10'd0;
            stable_frames <= 3'd0;
            absent_frames <= 4'd0;
            capture_armed <= 1'b1;
        end else begin
            if (frame_start) begin
                // Frame-level voting occurs before resetting the new frame.
                if (frame_candidate) begin
                    absent_frames <= 4'd0;
                    if (stable_frames < STABLE_FRAMES)
                        stable_frames <= stable_frames + 1'b1;
                    if (capture_armed &&
                        (stable_frames >= (STABLE_FRAMES - 1'b1))) begin
                        gesture_toggle <= ~gesture_toggle;
                        capture_armed <= 1'b0;
                        stable_frames <= STABLE_FRAMES;
                    end
                end else begin
                    stable_frames <= 3'd0;
                    if (!capture_armed) begin
                        if (absent_frames < REARM_FRAMES)
                            absent_frames <= absent_frames + 1'b1;
                        if (absent_frames >= (REARM_FRAMES - 1'b1))
                            capture_armed <= 1'b1;
                    end
                end

                skin_count <= 16'd0;
                skin_min_x <= 9'h1FF;
                skin_max_x <= 9'd0;
                skin_min_y <= 10'h3FF;
                skin_max_y <= 10'd0;
            end else if (skin_sample && sample_in_roi) begin
                if (skin_count != 16'hFFFF)
                    skin_count <= skin_count + 1'b1;
                if (sample_x_q < skin_min_x)
                    skin_min_x <= sample_x_q;
                if (sample_x_q > skin_max_x)
                    skin_max_x <= sample_x_q;
                if (sample_y_q < skin_min_y)
                    skin_min_y <= sample_y_q;
                if (sample_y_q > skin_max_y)
                    skin_max_y <= sample_y_q;
            end
        end
    end

endmodule
