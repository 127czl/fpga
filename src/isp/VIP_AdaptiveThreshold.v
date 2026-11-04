`timescale 1ns/1ps

// Frame adaptive edge threshold.
//
// The mean gradient of the frame is measured and the threshold is placed at a
// fixed multiple of it. A dim, low contrast scene gets a lower threshold and a
// bright high contrast scene a higher one, so the edge map keeps a similar
// density instead of needing to be re-tuned whenever the lighting changes.
//
// The manual key adjustment is added on top as an offset, so the competition's
// "raise / lower the threshold with the keys" requirement is fully preserved.
//
// Arithmetic (all explicit widths, no divider):
//     sum       = sum of the sampled gradients        (<= 2040*129600, 28 bits)
//     mean_q8   = (sum * 129) >> 16                   (= mean * 256)
//                 129/65536 = 0.0019684 which is 256/129600 = 0.0019753
//                 rounded down, a 0.35% error on the mean
//     threshold = (mean_q8 * GAIN_Q4) >> 12
//
// IMPORTANT: vsync in this design is "frame valid": HIGH while the active
// picture is sent and LOW during the frame sync period, so a frame is closed
// on the FALLING edge of vsync.
module VIP_AdaptiveThreshold #(
    parameter [13:0] IMG_HDISP = 14'd1920,
    parameter [13:0] IMG_VDISP = 14'd1080,
    // Q4 gain, 16 = 1.0x the mean gradient, 48 = 3.0x
    parameter [7:0]  GAIN_Q4   = 8'd48
    )(
    input               clk,
    input               rst_n,

    input               per_frame_vsync,
    input               per_frame_href,
    input       [12:0]  per_img_grad,       // 0 .. 2040
    input               per_img_valid,      // 0 for the border pixels

    output reg  [12:0]  adaptive_threshold  // in gradient units
    );

    // ---- one sample every 16th valid pixel ----
    reg [3:0] smp_cnt;
    wire      sample_now = per_frame_href && per_img_valid && (smp_cnt == 4'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            smp_cnt <= 4'd0;
        else if (!per_frame_href)
            smp_cnt <= 4'd0;
        else
            smp_cnt <= smp_cnt + 1'b1;
    end

    // ---- per frame accumulator ----
    reg [31:0] grad_sum;
    reg        vsync_d;
    wire       vsync_fall = vsync_d && !per_frame_vsync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            vsync_d <= 1'b0;
        else
            vsync_d <= per_frame_vsync;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            grad_sum <= 32'd0;
        else if (vsync_fall)
            grad_sum <= 32'd0;
        else if (sample_now)
            grad_sum <= grad_sum + {19'd0, per_img_grad};
    end

    // ---- scale to a Q8 mean, then apply the gain ----
    // Width care: in Verilog the width of `a * b` is the WIDEST OPERAND, not
    // the sum of the widths, so a narrow operand silently truncates the
    // product, and a narrow destination silently truncates the result.
    //   grad_sum  <= 2040 * 129600 = 264384000            (28 bits)
    //   * 129     <= 34105536000                          (36 bits)
    //   >> 16     <= 522240 = mean(max) * 256             (20 bits)
    //   * 48      <= 25067520                             (25 bits)
    //   >> 12     <= 6120, then clamped to 2040           (13 bits)
    wire [35:0] sum_scaled = grad_sum * 36'd129;
    wire [19:0] mean_q8    = sum_scaled[35:16];          // mean * 256
    wire [26:0] thr_scaled = mean_q8 * {19'd0, GAIN_Q4};
    wire [12:0] thr_raw    = thr_scaled[24:12];          // >> 12

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            adaptive_threshold <= 13'd192;
        else if (vsync_fall) begin
            if (grad_sum == 32'd0)
                adaptive_threshold <= 13'd192;          // no samples: keep sane
            else if (thr_raw > 13'd2040)
                adaptive_threshold <= 13'd2040;
            else if (thr_raw < 13'd8)
                adaptive_threshold <= 13'd8;            // never fully open
            else
                adaptive_threshold <= thr_raw;
        end
    end

endmodule
