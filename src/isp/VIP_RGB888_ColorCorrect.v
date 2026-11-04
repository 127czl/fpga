`timescale 1ns/1ps

// Lightweight display ISP for the 8-bit RGB path.
// Pipeline: black level -> white balance -> 3x3 CCM -> gamma -> RGB888.
module VIP_RGB888_ColorCorrect #(
    parameter [7:0] R_BLACK_LEVEL = 8'd0,
    parameter [7:0] G_BLACK_LEVEL = 8'd0,
    parameter [7:0] B_BLACK_LEVEL = 8'd0,

    // Q8 fixed-point gains: 256 = 1.00, 320 = 1.25, 224 = 0.875.
    parameter [9:0] R_GAIN_Q8 = 10'd320,
    parameter [9:0] G_GAIN_Q8 = 10'd224,
    parameter [9:0] B_GAIN_Q8 = 10'd320,

    // Display controls. 256 is neutral.
    parameter [9:0] SATURATION_Q8 = 10'd416,
    parameter [9:0] CONTRAST_Q8 = 10'd320,
    parameter [7:0] BLACK_CUTOFF = 8'd8,
    parameter [7:0] RED_GREEN_SUPPRESS_Q8 = 8'd48,
    parameter [7:0] RED_GREEN_BLUE_MAX = 8'd48,
    parameter [7:0] RED_GREEN_RED_MARGIN = 8'd24,

    // Shadow chroma suppression, applied in the gamma-encoded domain.
    // Below this luma the colour difference is faded back toward grey, so a
    // residual per-channel black offset or noise floor cannot show up as a
    // coloured black. Keep the knee a power of two: the chroma scale is
    // luma * (256 / SHADOW_LUMA_KNEE), implemented as a shift.
    parameter [7:0] SHADOW_LUMA_KNEE = 8'd64,

    // Backend AGC because SC2210 has no on-sensor AEC/AGC.
    parameter AUTO_GAIN_ENABLE = 1'b1,
    parameter [9:0] AUTO_GAIN_MIN_Q8 = 10'd128,
    parameter [9:0] AUTO_GAIN_MAX_Q8 = 10'd384,
    parameter [9:0] AUTO_GAIN_STEP_Q8 = 10'd4,
    parameter [7:0] AUTO_AVG_TARGET = 8'd88,
    parameter [7:0] AUTO_AVG_TOLERANCE = 8'd8,
    parameter [31:0] AUTO_FRAME_PIXELS = 32'd2073600,
    parameter [7:0] AUTO_SAMPLE_DIV = 8'd16,

    // Q8 signed color-correction matrix. Identity is the default.
    parameter signed [11:0] C_RR = 12'sd256,
    parameter signed [11:0] C_RG = 12'sd0,
    parameter signed [11:0] C_RB = 12'sd0,
    parameter signed [11:0] C_GR = 12'sd0,
    parameter signed [11:0] C_GG = 12'sd256,
    parameter signed [11:0] C_GB = 12'sd0,
    parameter signed [11:0] C_BR = 12'sd0,
    parameter signed [11:0] C_BG = 12'sd0,
    parameter signed [11:0] C_BB = 12'sd256,

    parameter ENABLE_GAMMA = 1'b1,
    parameter GAMMA_PROFILE = 1'b0
)(
    input               clk,
    input               rst_n,

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
    output reg  [7:0]   post_img_blue
);

    localparam [31:0] AUTO_SAMPLE_COUNT =
        AUTO_FRAME_PIXELS / AUTO_SAMPLE_DIV;
    localparam [31:0] AUTO_TARGET_SUM =
        AUTO_SAMPLE_COUNT * AUTO_AVG_TARGET;
    localparam [31:0] AUTO_LOWER_SUM =
        AUTO_TARGET_SUM - (AUTO_SAMPLE_COUNT * AUTO_AVG_TOLERANCE);
    localparam [31:0] AUTO_UPPER_SUM =
        AUTO_TARGET_SUM + (AUTO_SAMPLE_COUNT * AUTO_AVG_TOLERANCE);

    // 256 / 64 = 4 => shift by 2. Use 3 for a knee of 32, 1 for 128.
    localparam integer SHADOW_SCALE_SHIFT = 2;

    function [7:0] sub_black;
        input [7:0] pixel;
        input [7:0] black_level;
        begin
            sub_black = (pixel > black_level) ? (pixel - black_level) : 8'd0;
        end
    endfunction

    function [7:0] clip_u16;
        input [17:0] value;
        begin
            clip_u16 = (value[17:8] > 8'd255) ? 8'd255 : value[15:8];
        end
    endfunction

    function [7:0] clip_ccm;
        input signed [31:0] value;
        reg signed [31:0] rounded;
        begin
            rounded = value + 32'sd128;
            if (rounded < 0)
                clip_ccm = 8'd0;
            else if (rounded > 32'sd65280)
                clip_ccm = 8'd255;
            else
                clip_ccm = rounded[15:8];
        end
    endfunction

    function [7:0] clip_signed8;
        input signed [31:0] value;
        begin
            if (value < 0)
                clip_signed8 = 8'd0;
            else if (value > 32'sd255)
                clip_signed8 = 8'd255;
            else
                clip_signed8 = value[7:0];
        end
    endfunction

    // Piecewise-linear approximation of display gamma 2.2.
    function [7:0] gamma_2p2;
        input [7:0] value;
        reg [7:0] base;
        reg [7:0] delta;
        reg [8:0] interpolated;
        begin
            case (value[7:4])
                4'd0:  begin base = 8'd0;   delta = 8'd72; end
                4'd1:  begin base = 8'd72;  delta = 8'd27; end
                4'd2:  begin base = 8'd99;  delta = 8'd20; end
                4'd3:  begin base = 8'd119; delta = 8'd17; end
                4'd4:  begin base = 8'd136; delta = 8'd15; end
                4'd5:  begin base = 8'd151; delta = 8'd13; end
                4'd6:  begin base = 8'd164; delta = 8'd11; end
                4'd7:  begin base = 8'd175; delta = 8'd11; end
                4'd8:  begin base = 8'd186; delta = 8'd11; end
                4'd9:  begin base = 8'd197; delta = 8'd9;  end
                4'd10: begin base = 8'd206; delta = 8'd9;  end
                4'd11: begin base = 8'd215; delta = 8'd9;  end
                4'd12: begin base = 8'd224; delta = 8'd8;  end
                4'd13: begin base = 8'd232; delta = 8'd8;  end
                4'd14: begin base = 8'd240; delta = 8'd8;  end
                default: begin base = 8'd248; delta = 8'd7; end
            endcase
            interpolated = base +
                (({4'b0, delta} * {8'b0, value[3:0]} + 12'd8) >> 4);
            gamma_2p2 = (interpolated > 9'd255) ? 8'd255 : interpolated[7:0];
        end
    endfunction

    // Brighter display gamma for lifting midtones without lifting black.
    function [7:0] gamma_2p4;
        input [7:0] value;
        reg [7:0] base;
        reg [7:0] delta;
        reg [8:0] interpolated;
        begin
            case (value[7:4])
                4'd0:  begin base = 8'd0;   delta = 8'd80; end
                4'd1:  begin base = 8'd80;  delta = 8'd27; end
                4'd2:  begin base = 8'd107; delta = 8'd20; end
                4'd3:  begin base = 8'd127; delta = 8'd16; end
                4'd4:  begin base = 8'd143; delta = 8'd14; end
                4'd5:  begin base = 8'd157; delta = 8'd13; end
                4'd6:  begin base = 8'd170; delta = 8'd11; end
                4'd7:  begin base = 8'd181; delta = 8'd10; end
                4'd8:  begin base = 8'd191; delta = 8'd10; end
                4'd9:  begin base = 8'd201; delta = 8'd9;  end
                4'd10: begin base = 8'd210; delta = 8'd8;  end
                4'd11: begin base = 8'd218; delta = 8'd9;  end
                4'd12: begin base = 8'd227; delta = 8'd7;  end
                4'd13: begin base = 8'd234; delta = 8'd8;  end
                4'd14: begin base = 8'd242; delta = 8'd7;  end
                default: begin base = 8'd249; delta = 8'd6; end
            endcase
            interpolated = base +
                (({4'b0, delta} * {8'b0, value[3:0]} + 12'd8) >> 4);
            gamma_2p4 = (interpolated > 9'd255) ? 8'd255 : interpolated[7:0];
        end
    endfunction

    function [7:0] display_contrast;
        input [7:0] value;
        reg [7:0] cut_value;
        reg signed [31:0] adjusted;
        begin
            cut_value = (value > BLACK_CUTOFF) ? (value - BLACK_CUTOFF) : 8'd0;
            adjusted = (
                (($signed({1'b0, cut_value}) - 32'sd128) *
                 $signed({1'b0, CONTRAST_Q8})) >>> 8
            ) + 32'sd128;
            display_contrast = clip_signed8(adjusted);
        end
    endfunction

    wire [7:0] r_black = sub_black(per_img_red, R_BLACK_LEVEL);
    wire [7:0] g_black = sub_black(per_img_green, G_BLACK_LEVEL);
    wire [7:0] b_black = sub_black(per_img_blue, B_BLACK_LEVEL);

    wire [17:0] r_gain_mul = r_black * R_GAIN_Q8;
    wire [17:0] g_gain_mul = g_black * G_GAIN_Q8;
    wire [17:0] b_gain_mul = b_black * B_GAIN_Q8;

    wire [7:0] r_gain = clip_u16(r_gain_mul);
    wire [7:0] g_gain = clip_u16(g_gain_mul);
    wire [7:0] b_gain = clip_u16(b_gain_mul);

    reg [7:0] s1_r;
    reg [7:0] s1_g;
    reg [7:0] s1_b;
    reg       s1_vsync;
    reg       s1_href;
    reg       s1_hsync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_r <= 8'd0;
            s1_g <= 8'd0;
            s1_b <= 8'd0;
            s1_vsync <= 1'b0;
            s1_href <= 1'b0;
            s1_hsync <= 1'b0;
        end else begin
            s1_r <= r_gain;
            s1_g <= g_gain;
            s1_b <= b_gain;
            s1_vsync <= per_frame_vsync;
            s1_href <= per_frame_href;
            s1_hsync <= per_frame_hsync;
        end
    end

    wire signed [31:0] ccm_r_sum =
        ($signed(C_RR) * $signed({1'b0, s1_r})) +
        ($signed(C_RG) * $signed({1'b0, s1_g})) +
        ($signed(C_RB) * $signed({1'b0, s1_b}));

    wire signed [31:0] ccm_g_sum =
        ($signed(C_GR) * $signed({1'b0, s1_r})) +
        ($signed(C_GG) * $signed({1'b0, s1_g})) +
        ($signed(C_GB) * $signed({1'b0, s1_b}));

    wire signed [31:0] ccm_b_sum =
        ($signed(C_BR) * $signed({1'b0, s1_r})) +
        ($signed(C_BG) * $signed({1'b0, s1_g})) +
        ($signed(C_BB) * $signed({1'b0, s1_b}));

    wire [7:0] ccm_r = clip_ccm(ccm_r_sum);
    wire [7:0] ccm_g = clip_ccm(ccm_g_sum);
    wire [7:0] ccm_b = clip_ccm(ccm_b_sum);

    // Only remove green from strongly red-dominant pixels. Neutral, skin and
    // yellow colors are protected: after white balance a grey pixel still has
    // R slightly above G, so an extra red margin is required before the green
    // subtraction is allowed to fire. Without this margin the correction turned
    // the whole picture magenta.
    wire [8:0] red_green_ref = {1'b0, ccm_g} + {1'b0, RED_GREEN_RED_MARGIN};
    wire       red_green_active =
        (ccm_r > 8'd48) && ({1'b0, ccm_r} > red_green_ref) &&
        (ccm_b <= RED_GREEN_BLUE_MAX);
    wire [7:0] red_green_diff = red_green_active ? (ccm_r - ccm_g) : 8'd0;
    wire [15:0] red_green_correction =
        red_green_diff * RED_GREEN_SUPPRESS_Q8;
    wire [7:0] ccm_g_corrected =
        (ccm_g > red_green_correction[15:8]) ?
        (ccm_g - red_green_correction[15:8]) : 8'd0;

    // Frame-rate backend AGC. The sensor remains in its fixed exposure mode;
    // this block applies a slow digital gain correction between frames.
    wire [9:0] ccm_luma_sum =
        {1'b0, ccm_r} + {ccm_g_corrected, 1'b0} + {1'b0, ccm_b};
    wire [7:0] ccm_luma = ccm_luma_sum[9:2];

    reg [3:0]  auto_sample_phase;
    reg [31:0] auto_luma_sum;
    reg        s1_vsync_prev;
    reg [9:0]  auto_gain_q8;

    wire auto_sample_en = s1_href && (auto_sample_phase == 4'd0);
    wire auto_vsync_rise = s1_vsync && !s1_vsync_prev;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            auto_sample_phase <= 4'd0;
            auto_luma_sum <= 32'd0;
            s1_vsync_prev <= 1'b0;
            auto_gain_q8 <= 10'd256;
        end else begin
            s1_vsync_prev <= s1_vsync;

            if (!s1_href)
                auto_sample_phase <= 4'd0;
            else
                auto_sample_phase <= auto_sample_phase + 1'b1;

            if (auto_sample_en)
                auto_luma_sum <= auto_luma_sum + ccm_luma;

            if (auto_vsync_rise) begin
                if (AUTO_GAIN_ENABLE && (auto_luma_sum != 0)) begin
                    if ((auto_luma_sum < AUTO_LOWER_SUM) &&
                        (auto_gain_q8 < AUTO_GAIN_MAX_Q8))
                        auto_gain_q8 <= auto_gain_q8 + AUTO_GAIN_STEP_Q8;
                    else if ((auto_luma_sum > AUTO_UPPER_SUM) &&
                             (auto_gain_q8 > AUTO_GAIN_MIN_Q8))
                        auto_gain_q8 <= auto_gain_q8 - AUTO_GAIN_STEP_Q8;
                end
                auto_luma_sum <= 32'd0;
                auto_sample_phase <= 4'd0;
            end
        end
    end

    wire [9:0] auto_gain_eff = AUTO_GAIN_ENABLE ? auto_gain_q8 : 10'd256;
    wire [17:0] auto_r_mul = ccm_r * auto_gain_eff;
    wire [17:0] auto_g_mul = ccm_g_corrected * auto_gain_eff;
    wire [17:0] auto_b_mul = ccm_b * auto_gain_eff;
    wire [7:0] auto_r = clip_u16(auto_r_mul);
    wire [7:0] auto_g = clip_u16(auto_g_mul);
    wire [7:0] auto_b = clip_u16(auto_b_mul);

    reg [7:0] s2_r;
    reg [7:0] s2_g;
    reg [7:0] s2_b;
    reg       s2_vsync;
    reg       s2_href;
    reg       s2_hsync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_r <= 8'd0;
            s2_g <= 8'd0;
            s2_b <= 8'd0;
            s2_vsync <= 1'b0;
            s2_href <= 1'b0;
            s2_hsync <= 1'b0;
        end else begin
            s2_r <= auto_r;
            s2_g <= auto_g;
            s2_b <= auto_b;
            s2_vsync <= s1_vsync;
            s2_href <= s1_href;
            s2_hsync <= s1_hsync;
        end
    end

    // Register RGB and luma before the saturation multipliers.
    wire [9:0] luma_sum = {1'b0, s2_r} + {s2_g, 1'b0} + {1'b0, s2_b};
    wire [7:0] luma = luma_sum[9:2];
    reg [7:0] s3_r;
    reg [7:0] s3_g;
    reg [7:0] s3_b;
    reg [7:0] s3_luma;
    reg       s3_vsync;
    reg       s3_href;
    reg       s3_hsync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s3_r <= 8'd0;
            s3_g <= 8'd0;
            s3_b <= 8'd0;
            s3_luma <= 8'd0;
            s3_vsync <= 1'b0;
            s3_href <= 1'b0;
            s3_hsync <= 1'b0;
        end else begin
            s3_r <= s2_r;
            s3_g <= s2_g;
            s3_b <= s2_b;
            s3_luma <= luma;
            s3_vsync <= s2_vsync;
            s3_href <= s2_href;
            s3_hsync <= s2_hsync;
        end
    end

    wire signed [31:0] sat_r_sum =
        $signed({1'b0, s3_luma}) +
        ((($signed({1'b0, s3_r}) - $signed({1'b0, s3_luma})) *
          $signed({1'b0, SATURATION_Q8})) >>> 8);

    wire signed [31:0] sat_g_sum =
        $signed({1'b0, s3_luma}) +
        ((($signed({1'b0, s3_g}) - $signed({1'b0, s3_luma})) *
          $signed({1'b0, SATURATION_Q8})) >>> 8);

    wire signed [31:0] sat_b_sum =
        $signed({1'b0, s3_luma}) +
        ((($signed({1'b0, s3_b}) - $signed({1'b0, s3_luma})) *
          $signed({1'b0, SATURATION_Q8})) >>> 8);

    wire [7:0] sat_r = clip_signed8(sat_r_sum);
    wire [7:0] sat_g = clip_signed8(sat_g_sum);
    wire [7:0] sat_b = clip_signed8(sat_b_sum);

    reg [7:0] s4_r;
    reg [7:0] s4_g;
    reg [7:0] s4_b;
    reg       s4_vsync;
    reg       s4_href;
    reg       s4_hsync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s4_r <= 8'd0;
            s4_g <= 8'd0;
            s4_b <= 8'd0;
            s4_vsync <= 1'b0;
            s4_href <= 1'b0;
            s4_hsync <= 1'b0;
        end else begin
            s4_r <= sat_r;
            s4_g <= sat_g;
            s4_b <= sat_b;
            s4_vsync <= s3_vsync;
            s4_href <= s3_href;
            s4_hsync <= s3_hsync;
        end
    end

    wire [7:0] gamma_r = !ENABLE_GAMMA ? s4_r :
        (GAMMA_PROFILE ? gamma_2p4(s4_r) : gamma_2p2(s4_r));
    wire [7:0] gamma_g = !ENABLE_GAMMA ? s4_g :
        (GAMMA_PROFILE ? gamma_2p4(s4_g) : gamma_2p2(s4_g));
    wire [7:0] gamma_b = !ENABLE_GAMMA ? s4_b :
        (GAMMA_PROFILE ? gamma_2p4(s4_b) : gamma_2p2(s4_b));

    reg [7:0] s5_r;
    reg [7:0] s5_g;
    reg [7:0] s5_b;
    reg       s5_vsync;
    reg       s5_href;
    reg       s5_hsync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s5_r <= 8'd0;
            s5_g <= 8'd0;
            s5_b <= 8'd0;
            s5_vsync <= 1'b0;
            s5_href <= 1'b0;
            s5_hsync <= 1'b0;
        end else begin
            s5_r <= gamma_r;
            s5_g <= gamma_g;
            s5_b <= gamma_b;
            s5_vsync <= s4_vsync;
            s5_href <= s4_href;
            s5_hsync <= s4_hsync;
        end
    end

    // Fade the colour difference out below the shadow knee. At or above the
    // knee the scale is 1.00 and the pixel passes through untouched.
    wire [9:0] s5_luma_sum = {1'b0, s5_r} + {s5_g, 1'b0} + {1'b0, s5_b};
    wire [7:0] s5_luma = s5_luma_sum[9:2];
    wire [9:0] shadow_scale = (s5_luma >= SHADOW_LUMA_KNEE) ?
        10'd256 : ({2'b00, s5_luma} << SHADOW_SCALE_SHIFT);

    wire signed [31:0] shadow_r_sum =
        $signed({1'b0, s5_luma}) +
        ((($signed({1'b0, s5_r}) - $signed({1'b0, s5_luma})) *
          $signed({1'b0, shadow_scale})) >>> 8);

    wire signed [31:0] shadow_g_sum =
        $signed({1'b0, s5_luma}) +
        ((($signed({1'b0, s5_g}) - $signed({1'b0, s5_luma})) *
          $signed({1'b0, shadow_scale})) >>> 8);

    wire signed [31:0] shadow_b_sum =
        $signed({1'b0, s5_luma}) +
        ((($signed({1'b0, s5_b}) - $signed({1'b0, s5_luma})) *
          $signed({1'b0, shadow_scale})) >>> 8);

    wire [7:0] shadow_r = clip_signed8(shadow_r_sum);
    wire [7:0] shadow_g = clip_signed8(shadow_g_sum);
    wire [7:0] shadow_b = clip_signed8(shadow_b_sum);

    // Register the shadow stage so the blend and the display contrast curve
    // do not sit in the same timing path.
    reg [7:0] s6_r;
    reg [7:0] s6_g;
    reg [7:0] s6_b;
    reg       s6_vsync;
    reg       s6_href;
    reg       s6_hsync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s6_r <= 8'd0;
            s6_g <= 8'd0;
            s6_b <= 8'd0;
            s6_vsync <= 1'b0;
            s6_href <= 1'b0;
            s6_hsync <= 1'b0;
        end else begin
            s6_r <= shadow_r;
            s6_g <= shadow_g;
            s6_b <= shadow_b;
            s6_vsync <= s5_vsync;
            s6_href <= s5_href;
            s6_hsync <= s5_hsync;
        end
    end

    wire [7:0] display_r = display_contrast(s6_r);
    wire [7:0] display_g = display_contrast(s6_g);
    wire [7:0] display_b = display_contrast(s6_b);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            post_img_red <= 8'd0;
            post_img_green <= 8'd0;
            post_img_blue <= 8'd0;
            post_frame_vsync <= 1'b0;
            post_frame_href <= 1'b0;
            post_frame_hsync <= 1'b0;
        end else begin
            post_img_red <= display_r;
            post_img_green <= display_g;
            post_img_blue <= display_b;
            post_frame_vsync <= s6_vsync;
            post_frame_href <= s6_href;
            post_frame_hsync <= s6_hsync;
        end
    end

endmodule
