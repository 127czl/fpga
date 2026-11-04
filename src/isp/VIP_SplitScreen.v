`timescale 1ns/1ps

// Continuous left/right split screen.
//
// The two halves are the two halves of the SAME source line:
//   left  half (0..959)  : original columns 0..959, grayscale
//   right half (960..1919): original columns 960..1919, edge strength
//
// A ping-pong line buffer is used so the current line is written while the
// previous line is read. This avoids same-address read/write hazards and keeps
// the two halves spatially continuous instead of horizontally compressing the
// full image into each half.
module VIP_SplitScreen #(
    parameter [13:0] IMG_HDISP = 14'd1920
    )(
    input               clk,
    input               rst_n,

    input               per_frame_vsync,
    input               per_frame_href,
    input               per_frame_hsync,
    input       [7:0]   per_img_gray,
    input       [7:0]   per_img_edge,

    output reg          post_frame_vsync,
    output reg          post_frame_href,
    output reg          post_frame_hsync,
    output reg  [7:0]   post_img_red,
    output reg  [7:0]   post_img_green,
    output reg  [7:0]   post_img_blue
    );

    localparam [11:0] HALF_WIDTH = IMG_HDISP >> 1;
    localparam [11:0] LINE_WORDS = IMG_HDISP;

    reg [11:0] x_cnt;
    reg        href_d;
    reg        vsync_d;
    wire       line_end = href_d && !per_frame_href;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_cnt   <= 12'd0;
            href_d  <= 1'b0;
            vsync_d <= 1'b0;
        end else begin
            href_d  <= per_frame_href;
            vsync_d <= per_frame_vsync;

            if (per_frame_href) begin
                if (x_cnt < IMG_HDISP - 1'b1)
                    x_cnt <= x_cnt + 1'b1;
            end else begin
                x_cnt <= 12'd0;
            end
        end
    end

    // Two adjacent line banks. One is written while the other is read.
    reg [15:0] line_mem [0:2*IMG_HDISP-1];
    reg        wr_bank;
    reg [15:0] rd_data;
    reg        rd_left;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            wr_bank <= 1'b0;
        else if (line_end)
            wr_bank <= ~wr_bank;
    end

    wire [11:0] wr_addr = (wr_bank ? LINE_WORDS : 12'd0) + x_cnt;
    wire [11:0] rd_addr = ((!wr_bank) ? LINE_WORDS : 12'd0) + x_cnt;

    always @(posedge clk) begin
        if (per_frame_href)
            line_mem[wr_addr] <= {per_img_gray, per_img_edge};
    end

    always @(posedge clk) begin
        rd_data <= line_mem[rd_addr];
        rd_left <= (x_cnt < HALF_WIDTH);
    end

    reg [7:0] px_r, px_g, px_b;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            px_r <= 8'd0;
            px_g <= 8'd0;
            px_b <= 8'd0;
        end else if (rd_left) begin
            px_r <= rd_data[15:8];
            px_g <= rd_data[15:8];
            px_b <= rd_data[15:8];
        end else begin
            px_r <= rd_data[7:0];
            px_g <= rd_data[7:0];
            px_b <= rd_data[7:0];
        end
    end

    reg [1:0] v_sr, h_sr, s_sr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_sr <= 2'b00;
            h_sr <= 2'b00;
            s_sr <= 2'b00;
            post_img_red     <= 8'd0;
            post_img_green   <= 8'd0;
            post_img_blue    <= 8'd0;
            post_frame_vsync <= 1'b0;
            post_frame_href  <= 1'b0;
            post_frame_hsync <= 1'b0;
        end else begin
            v_sr <= {v_sr[0], per_frame_vsync};
            h_sr <= {h_sr[0], per_frame_href};
            s_sr <= {s_sr[0], per_frame_hsync};

            post_img_red     <= px_r;
            post_img_green   <= px_g;
            post_img_blue    <= px_b;
            post_frame_vsync <= v_sr[1];
            post_frame_href  <= h_sr[1];
            post_frame_hsync <= s_sr[1];
        end
    end
endmodule
