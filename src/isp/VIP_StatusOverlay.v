`timescale 1ns/1ps

// DDR task status overlay.
//
// It draws a three-digit decimal number and one of four simple status icons:
//   1 = red filled square     (recording)
//   2 = red hollow square     (stopped / paused)
//   3 = green triangle        (playing)
//
// The three digits are built from a 5x7 glyph, scaled x8.  They sit in the
// top-left corner, away from the usual centre of the scene.
module VIP_StatusOverlay #(
    parameter [13:0] IMG_HDISP = 14'd1920,
    parameter [13:0] IMG_VDISP = 14'd1080
    )(
    input               clk,
    input               rst_n,

    input       [9:0]   status_number,
    input       [1:0]   status_icon,

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

    localparam [13:0] NUM_X = 14'd64;
    localparam [13:0] NUM_Y = 14'd64;
    localparam [13:0] ICON_X = 14'd64;
    localparam [13:0] ICON_Y = 14'd140;

    reg [13:0] x_cnt;
    reg [13:0] y_cnt;
    reg        href_d;
    reg        vsync_d;
    reg [9:0]  s1_number;
    reg [1:0]  s1_icon;
    reg [13:0] s1_x;
    reg [13:0] s1_y;
    reg        s1_vsync, s1_href, s1_hsync;
    reg [7:0]  s1_red, s1_green, s1_blue;
    reg        s2_glyph_on;
    reg        s2_icon_rec, s2_icon_stop, s2_icon_play;
    reg        s2_vsync, s2_href, s2_hsync;
    reg [7:0]  s2_red, s2_green, s2_blue;

    wire href_rise  = per_frame_href && !href_d;
    wire vsync_fall = vsync_d && !per_frame_vsync;

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

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_number <= 10'd0;
            s1_icon   <= 2'd0;
            s1_x      <= 14'd0;
            s1_y      <= 14'd0;
            s1_vsync  <= 1'b0;
            s1_href   <= 1'b0;
            s1_hsync  <= 1'b0;
            s1_red    <= 8'd0;
            s1_green  <= 8'd0;
            s1_blue   <= 8'd0;
        end else begin
            s1_number <= status_number;
            s1_icon   <= status_icon;
            s1_x      <= x_cnt;
            s1_y      <= y_cnt;
            s1_vsync  <= per_frame_vsync;
            s1_href   <= per_frame_href;
            s1_hsync  <= per_frame_hsync;
            s1_red    <= per_img_red;
            s1_green  <= per_img_green;
            s1_blue   <= per_img_blue;
        end
    end

    // ---------------------------------------------------------------
    // Decimal digits, without a divider in the RTL
    // ---------------------------------------------------------------
    function [3:0] digit_hundreds;
        input [9:0] n;
        begin
            if      (n >= 10'd900) digit_hundreds = 4'd9;
            else if (n >= 10'd800) digit_hundreds = 4'd8;
            else if (n >= 10'd700) digit_hundreds = 4'd7;
            else if (n >= 10'd600) digit_hundreds = 4'd6;
            else if (n >= 10'd500) digit_hundreds = 4'd5;
            else if (n >= 10'd400) digit_hundreds = 4'd4;
            else if (n >= 10'd300) digit_hundreds = 4'd3;
            else if (n >= 10'd200) digit_hundreds = 4'd2;
            else if (n >= 10'd100) digit_hundreds = 4'd1;
            else                    digit_hundreds = 4'd0;
        end
    endfunction

    function [3:0] digit_tens;
        input [9:0] n;
        begin
            if      (n >= 10'd90) digit_tens = 4'd9;
            else if (n >= 10'd80) digit_tens = 4'd8;
            else if (n >= 10'd70) digit_tens = 4'd7;
            else if (n >= 10'd60) digit_tens = 4'd6;
            else if (n >= 10'd50) digit_tens = 4'd5;
            else if (n >= 10'd40) digit_tens = 4'd4;
            else if (n >= 10'd30) digit_tens = 4'd3;
            else if (n >= 10'd20) digit_tens = 4'd2;
            else if (n >= 10'd10) digit_tens = 4'd1;
            else                   digit_tens = 4'd0;
        end
    endfunction

    function [3:0] digit_ones;
        input [9:0] n;
        begin
            if      (n >= 10'd9) digit_ones = 4'd9;
            else if (n >= 10'd8) digit_ones = 4'd8;
            else if (n >= 10'd7) digit_ones = 4'd7;
            else if (n >= 10'd6) digit_ones = 4'd6;
            else if (n >= 10'd5) digit_ones = 4'd5;
            else if (n >= 10'd4) digit_ones = 4'd4;
            else if (n >= 10'd3) digit_ones = 4'd3;
            else if (n >= 10'd2) digit_ones = 4'd2;
            else if (n >= 10'd1) digit_ones = 4'd1;
            else                  digit_ones = 4'd0;
        end
    endfunction

    wire [3:0] hundreds = digit_hundreds(s1_number);
    wire [9:0] hundreds_val = {6'd0, hundreds} * 10'd100;
    wire [9:0] rem100 = s1_number - hundreds_val;
    wire [3:0] tens = digit_tens(rem100);
    wire [9:0] tens_val = {6'd0, tens} * 10'd10;
    wire [9:0] rem10 = rem100 - tens_val;
    wire [3:0] ones = digit_ones(rem10);

    function [34:0] digit_glyph;
        input [3:0] d;
        begin
            case (d)
                4'd0: digit_glyph = 35'b11111_10001_10001_10001_10001_10001_11111;
                4'd1: digit_glyph = 35'b00100_01100_00100_00100_00100_00100_01110;
                4'd2: digit_glyph = 35'b11110_00001_00001_11110_10000_10000_11111;
                4'd3: digit_glyph = 35'b11111_00001_00001_01111_00001_00001_11111;
                4'd4: digit_glyph = 35'b10001_10001_10001_11111_00001_00001_00001;
                4'd5: digit_glyph = 35'b11111_10000_10000_11111_00001_00001_11111;
                4'd6: digit_glyph = 35'b01111_10000_10000_11111_10001_10001_11111;
                4'd7: digit_glyph = 35'b11111_00001_00010_00100_01000_01000_01000;
                4'd8: digit_glyph = 35'b11111_10001_10001_11111_10001_10001_11111;
                default: digit_glyph = 35'b11111_10001_10001_11111_00001_00001_11110;
            endcase
        end
    endfunction

    wire        num_area = (s1_x >= NUM_X) && (s1_x < NUM_X + 14'd136) &&
                           (s1_y >= NUM_Y) && (s1_y < NUM_Y + 14'd56);
    wire [13:0] num_x = s1_x - NUM_X;
    wire [1:0]  num_sel = (num_x < 14'd40) ? 2'd0 :
                          (num_x < 14'd88) ? 2'd1 : 2'd2;
    wire [13:0] num_dx = (num_sel == 2'd0) ? num_x :
                         (num_sel == 2'd1) ? (num_x - 14'd48) :
                                             (num_x - 14'd96);
    wire [3:0]  glyph_col = num_dx >> 3;
    wire [3:0]  glyph_row = (s1_y - NUM_Y) >> 3;
    wire [3:0]  glyph_value = (num_sel == 2'd0) ? hundreds :
                              (num_sel == 2'd1) ? tens : ones;
    wire [5:0]  glyph_index = ({2'b00, glyph_row} * 6'd5) +
                              {2'b00, glyph_col};
    wire [34:0] glyph_bits = digit_glyph(glyph_value);
    wire        glyph_on = num_area && (s1_number != 10'd0) &&
                           (glyph_row < 4'd7) &&
                           (glyph_col < 4'd5) &&
                           glyph_bits[6'd34 - glyph_index];

    // ---------------------------------------------------------------
    // Record / stop / play icon
    // ---------------------------------------------------------------
    wire        icon_area = (s1_x >= ICON_X) && (s1_x < ICON_X + 14'd32) &&
                            (s1_y >= ICON_Y) && (s1_y < ICON_Y + 14'd32);
    wire [5:0]  icon_x = (s1_x - ICON_X);
    wire [5:0]  icon_y = (s1_y - ICON_Y);
    wire        icon_rec    = icon_area && (s1_icon == 2'd1) &&
                              (icon_x >= 6'd8) && (icon_x < 6'd24) &&
                              (icon_y >= 6'd8) && (icon_y < 6'd24);
    wire        icon_stop   = icon_area && (s1_icon == 2'd2) &&
                              (icon_x >= 6'd8) && (icon_x < 6'd24) &&
                              (icon_y >= 6'd8) && (icon_y < 6'd24) &&
                              ((icon_x == 6'd8) || (icon_x == 6'd23) ||
                               (icon_y == 6'd8) || (icon_y == 6'd23));
    wire [5:0]  tri_x = (icon_x >= 6'd8) ? (icon_x - 6'd8) : 6'd0;
    wire [5:0]  tri_y = (icon_y >= 6'd8) ? (icon_y - 6'd8) : 6'd0;
    wire        icon_play = icon_area && (s1_icon == 2'd3) &&
                            (tri_y < 6'd16) && (tri_x < 6'd16) &&
                            ((tri_x * 6'd2) <= tri_y);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_glyph_on <= 1'b0;
            s2_icon_rec <= 1'b0;
            s2_icon_stop <= 1'b0;
            s2_icon_play <= 1'b0;
            s2_vsync <= 1'b0;
            s2_href  <= 1'b0;
            s2_hsync <= 1'b0;
            s2_red   <= 8'd0;
            s2_green <= 8'd0;
            s2_blue  <= 8'd0;
        end else begin
            s2_glyph_on  <= glyph_on;
            s2_icon_rec  <= icon_rec;
            s2_icon_stop <= icon_stop;
            s2_icon_play <= icon_play;
            s2_vsync     <= s1_vsync;
            s2_href      <= s1_href;
            s2_hsync     <= s1_hsync;
            s2_red       <= s1_red;
            s2_green     <= s1_green;
            s2_blue      <= s1_blue;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            post_frame_vsync <= 1'b0;
            post_frame_href  <= 1'b0;
            post_frame_hsync <= 1'b0;
            post_img_red     <= 8'd0;
            post_img_green   <= 8'd0;
            post_img_blue    <= 8'd0;
        end else begin
            post_frame_vsync <= s2_vsync;
            post_frame_href  <= s2_href;
            post_frame_hsync <= s2_hsync;

            if (s2_glyph_on) begin
                post_img_red   <= 8'hFF;
                post_img_green <= 8'hFF;
                post_img_blue  <= 8'hFF;
            end else if (s2_icon_rec) begin
                post_img_red   <= 8'hFF;
                post_img_green <= 8'h00;
                post_img_blue  <= 8'h00;
            end else if (s2_icon_stop) begin
                post_img_red   <= 8'hFF;
                post_img_green <= 8'hFF;
                post_img_blue  <= 8'hFF;
            end else if (s2_icon_play) begin
                post_img_red   <= 8'h00;
                post_img_green <= 8'hFF;
                post_img_blue  <= 8'h00;
            end else begin
                post_img_red   <= s2_red;
                post_img_green <= s2_green;
                post_img_blue  <= s2_blue;
            end
        end
    end

endmodule
