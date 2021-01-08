// femtorv32, a minimalistic RISC-V RV32I core
//       Bruno Levy, 2020-2021
//
// This file: FGA: Femto Graphics Adapter
//   Note: VRAM is write-only ! (the read port is used by HDMI)
//   3 modes: 320x200 truecolor   16bpp
//            320x200 colormapped  8bpp
//            640x400 colormapped  4bpp
//   Hardware emulation of SSD1351 "window write" command in the
//    three modes for OLED-HDMI mirroring
//   Hardware-accelerated 'fillrect' command: fills one pixel per
//    clock (7 times faster than software).

`include "HDMI_clock.v"
`include "TMDS_encoder.v"

module FGA(
    input wire 	      clk,         // system clock
    input wire 	      sel,         // if zero, writes are ignored
    input wire [3:0]  mem_wmask,   // mem write mask and strobe
    input wire [16:0] mem_address, // address in graphic memory (128K), word-aligned
    input wire [31:0] mem_wdata,   // data to be written

    input wire        pixel_clk,   // 25 MHz	   
    output wire [3:0] gpdi_dp,     // HDMI signals, blue, green, red, clock
                                   // dgpi_dn generated by pins (see ulx3s.lpf)

    input  wire io_wstrb,
    input  wire io_rstrb,
    input  wire sel_cntl,          // select control register (R/W)
    input  wire sel_dat,           // select data in (W)
    output wire	[31:0] rdata       // data read from register
);

   reg [31:0] VRAM[32767:0];
   reg [23:0] PALETTE[255:0];
   reg [1:0]  MODE;
   reg [18:0] ORIGIN;

   /************************* HDMI signal generation ***************************/

   localparam MODE_320x200x16bpp = 2'b00;
   localparam MODE_320x200x8bpp  = 2'b01;
   localparam MODE_640x400x4bpp  = 2'b10;
   
   // This part is just like a VGA generator.
   reg  [9:0] X, Y;   // current pixel coordinates
   reg hSync, vSync; // horizontal and vertical synchronization
   reg DrawArea;     // asserted if current pixel is in drawing area
   reg mem_busy;     // asserted if memory transfer is running.
   
   // read control register
   assign rdata = (io_rstrb && sel_cntl) ? 
                  {(Y >= 400),(X >= 640),DrawArea,mem_busy,4'b0,2'b0,X,2'b0,Y} : 
                  32'b0;

   // Stage 0: X,Y,vsync,hsync generation
   always @(posedge pixel_clk) begin
      DrawArea <= (X<640) && (Y<480);
      X        <= (X==799) ? 0 : X+1;
      if(X==799) Y <= (Y==524) ? 0 : Y+1;
      hSync <= (X>=656) && (X<752);
      vSync <= (Y>=490) && (Y<492);
   end

   // Stage 1: pixel address generation
   reg [17:0] pix_address;
   reg [17:0] row_start_pix_address;
   always @(posedge pixel_clk) begin
      if(MODE == MODE_320x200x16bpp ||
	 MODE == MODE_320x200x8bpp) begin
	 if(X == 0) begin
	    if(Y == 0) begin
	       if(MODE == MODE_320x200x16bpp) begin
		  row_start_pix_address <= ORIGIN[18:1]; // 16bpp, addr2pixaddr: /2
		  pix_address           <= ORIGIN[18:1];
	       end else begin
		  row_start_pix_address <= ORIGIN[17:0]; // 8bpp
		  pix_address           <= ORIGIN[17:0];
	       end
	    end else begin
	       // Increment row address every 2 Y (2 because 320x200->640x400)
	       if(Y[0]) begin
		  row_start_pix_address <= row_start_pix_address + 320;
		  pix_address           <= row_start_pix_address + 320;
	       end else begin
		  pix_address <= row_start_pix_address;	       
	       end
	    end
	 end 
	 if(X[0]) pix_address <= pix_address + 1;
      end else begin // MODE_640x400x4bpp
	 if(X == 0) begin
	    if(Y == 0) begin
	       row_start_pix_address <= {ORIGIN[16:0],1'b0}; // 4bpp, addr2pixaddr: *2
	       pix_address           <= {ORIGIN[16:0],1'b0};
	    end else begin
	       row_start_pix_address <= row_start_pix_address + 640;
	       pix_address           <= row_start_pix_address + 640;
	    end
	 end else begin
	    pix_address <= pix_address + 1;
	 end
      end
   end 

   // Stage 2: pixel data fetch
   reg [14:0] word_address;
   always @(*) begin
      (* parallel_case, full_case *)
      case(MODE)
	MODE_320x200x16bpp: word_address = pix_address[15:1];
	MODE_320x200x8bpp:  word_address = pix_address[16:2];
	MODE_640x400x4bpp:  word_address = pix_address[17:3];
	2'b11:              word_address = 0;
      endcase
   end
   reg [17:0] pix_address_2;
   reg [31:0] pix_word_data_2;
   always @(posedge pixel_clk) begin
      pix_address_2 <= pix_address;
      pix_word_data_2 <= VRAM[word_address];
   end

   // Stage 3: colormap lookup
   reg [7:0] pix_color_index_3;
   always @(*) begin
      (* parallel_case, full_case *)
      case(MODE)
	MODE_320x200x16bpp: begin
	   pix_color_index_3 = 8'd0;
	end
	MODE_320x200x8bpp:  begin
	   case(pix_address_2[1:0])
	     2'b00: pix_color_index_3 = pix_word_data_2[ 7:0 ];
	     2'b01: pix_color_index_3 = pix_word_data_2[15:8 ];
	     2'b10: pix_color_index_3 = pix_word_data_2[23:16];
	     2'b11: pix_color_index_3 = pix_word_data_2[31:24];
	   endcase
	end
	MODE_640x400x4bpp:  begin
	   case(pix_address_2[2:0])
	     3'b000: pix_color_index_3 = {4'b0000, pix_word_data_2[ 3:0 ]};
	     3'b001: pix_color_index_3 = {4'b0000, pix_word_data_2[ 7:4 ]};
	     3'b010: pix_color_index_3 = {4'b0000, pix_word_data_2[11:8 ]};
	     3'b011: pix_color_index_3 = {4'b0000, pix_word_data_2[15:12]};
	     3'b100: pix_color_index_3 = {4'b0000, pix_word_data_2[19:16]};
	     3'b101: pix_color_index_3 = {4'b0000, pix_word_data_2[23:20]};
	     3'b110: pix_color_index_3 = {4'b0000, pix_word_data_2[27:24]};
	     3'b111: pix_color_index_3 = {4'b0000, pix_word_data_2[31:28]};
	   endcase
	end 
	2'b11: pix_color_index_3 = 8'd0;
      endcase
   end
   
   reg [7:0]  R,G,B;
   always @(posedge pixel_clk) begin
      if(MODE == MODE_320x200x16bpp) begin
	   if(pix_address_2[0]) begin 
	      R <= {pix_word_data_2[31:27],3'b000};
	      G <= {pix_word_data_2[26:21],2'b00 };
	      B <= {pix_word_data_2[20:16],3'b000};
	   end else begin
	      R <= {pix_word_data_2[15:11],3'b000};
	      G <= {pix_word_data_2[10:5 ],2'b00 };
	      B <= {pix_word_data_2[ 4:0 ],3'b000};
	   end
      end else begin
	 {R,G,B} <= PALETTE[pix_color_index_3];
      end
      // First pixel is boring, normally I should prefetch it...
      if(X == 0 || X == 1 || Y >= 400) begin R <= 0; G <= 0; B <= 0; end
   end

   
   // RGB TMDS encoding
   // Generate 10-bits TMDS red,green,blue signals. Blue embeds HSync/VSync in its 
   // control part.
   wire [9:0] TMDS_R, TMDS_G, TMDS_B;
   TMDS_encoder encode_R(.clk(pixel_clk), .VD(R), .CD(2'b00)        , .VDE(DrawArea), .TMDS(TMDS_R));
   TMDS_encoder encode_G(.clk(pixel_clk), .VD(G), .CD(2'b00)        , .VDE(DrawArea), .TMDS(TMDS_G));
   TMDS_encoder encode_B(.clk(pixel_clk), .VD(B), .CD({vSync,hSync}), .VDE(DrawArea), .TMDS(TMDS_B));

   // 250 MHz clock 
   // This one needs some FPGA-specific specialized blocks (a PLL).
   wire clk_TMDS; // The 250 MHz clock used by the serializers.
   HDMI_clock hdmi_clock(.clk(pixel_clk), .hdmi_clk(clk_TMDS));

   // Modulo-10 clock divider (my version, using a 1-hot in a 10 bits ring)
   reg [9:0] TMDS_mod10=1;
   wire      TMDS_shift_load = TMDS_mod10[9];
   always @(posedge clk_TMDS) TMDS_mod10 <= {TMDS_mod10[8:0],TMDS_mod10[9]};

   // Shifters
   // Every 10 clocks, we get a fresh R,G,B triplet from the TMDS encoders,
   // else we shift.
   reg [9:0] TMDS_shift_R=0, TMDS_shift_G=0, TMDS_shift_B=0;
   always @(posedge clk_TMDS) begin
      TMDS_shift_R <= TMDS_shift_load ? TMDS_R : {1'b0,TMDS_shift_R[9:1]};
      TMDS_shift_G <= TMDS_shift_load ? TMDS_G : {1'b0,TMDS_shift_G[9:1]};
      TMDS_shift_B <= TMDS_shift_load ? TMDS_B : {1'b0,TMDS_shift_B[9:1]};	
   end

   // HDMI signal, positive part of the differential pairs
   // (negative part generated by the pins, see ulx3s.lpf)
   assign gpdi_dp[2] = TMDS_shift_R[0];
   assign gpdi_dp[1] = TMDS_shift_G[0];
   assign gpdi_dp[0] = TMDS_shift_B[0];
   assign gpdi_dp[3] = pixel_clk;

   /*************************************************************************/

   // control register - commands

   localparam SET_MODE       = 8'd0; 
   localparam SET_PALETTE_R  = 8'd1; 
   localparam SET_PALETTE_G  = 8'd2; 
   localparam SET_PALETTE_B  = 8'd3; 
   localparam SET_WWINDOW_X  = 8'd4;
   localparam SET_WWINDOW_Y  = 8'd5;
   localparam SET_ORIGIN     = 8'd6;
   localparam FILLRECT       = 8'd7;
   
   // Emulation of SSD1351 OLED display.
   // - write window command, two commands:
   //     (send 32 bits to IO_FGA_CNTL hardware register)
   //   CMD=4: SET_WWINDOW_X: X2[11:0] X1[11:0] CMD[7:0]
   //   CMD=5: SET_WWINDOW_Y: Y2[11:0] Y1[11:0] CMD[7:0]
   //
   // - write data: send 8 bits to IO_FGA_DAT hardware register
   //    MSB first, encoding follows SSD1351: RRRRR GGGGG 0 BBBBB
   
   reg[11:0] window_x1, window_x2, window_y1, window_y2, window_x, window_y;
   reg [17:0] window_row_start;
   reg [17:0] window_pixel_address;
   reg [15:0] fill_color;
   reg        fill_rect;

   wire [17:0] WIDTH = (MODE == MODE_640x400x4bpp) ? 640 : 320;
   
   always @(posedge clk) begin
      if(mem_busy && ((io_wstrb && sel_dat) || fill_rect)) begin
	 window_pixel_address <= window_pixel_address + 1;
	 window_x             <= window_x + 1;	    
	 if(window_x == window_x2) begin
	    if(window_y == window_y2) begin
	       mem_busy  <= 1'b0;
	       fill_rect <= 1'b0;
	    end else begin
	       window_y <= window_y+1;
	       window_x <= window_x1;
	       window_pixel_address <= window_row_start + WIDTH;
	       window_row_start     <= window_row_start + WIDTH;
	    end
	 end 
      end
      
      if(io_wstrb && sel_cntl) begin
	 /* verilator lint_off CASEINCOMPLETE */
	 case(mem_wdata[7:0])
	   SET_MODE:      begin
	       MODE      <= mem_wdata[9:8];
	       fill_rect <= 1'b0;
	       mem_busy  <= 1'b0;
	   end
	   SET_ORIGIN:    ORIGIN <= mem_wdata[18:0]; 
	   SET_PALETTE_B: PALETTE[mem_wdata[15:8]][7:0]   <= mem_wdata[23:16];
	   SET_PALETTE_G: PALETTE[mem_wdata[15:8]][15:8]  <= mem_wdata[23:16];
	   SET_PALETTE_R: PALETTE[mem_wdata[15:8]][23:16] <= mem_wdata[23:16];
	   SET_WWINDOW_X: begin 
	      window_x1 <= mem_wdata[19:8];
	      window_x2 <= mem_wdata[31:20];
	      window_x  <= mem_wdata[19:8];
	      mem_busy  <= 1'b1;
	   end
	   SET_WWINDOW_Y: begin 
	      window_y1 <= mem_wdata[19:8];
	      window_y2 <= mem_wdata[31:20];
	      window_y  <= mem_wdata[19:8];
	      mem_busy  <= 1'b1;
	      /* verilator lint_off WIDTH */
	      window_row_start     <= mem_wdata[19:8] * WIDTH + window_x1;
	      window_pixel_address <= mem_wdata[19:8] * WIDTH + window_x1;
	      /* verilator lint_on WIDTH */		 
	   end
	   FILLRECT: begin
	      fill_rect  <= 1'b1;
	      fill_color <= mem_wdata[23:8];
	   end
	 endcase
	 /* verilator lint_on CASEINCOMPLETE */	    
      end 
   end 

   
   // write VRAM (interface with processor)
   wire [14:0] vram_word_address = mem_address[16:2];
   wire [15:0] pixel_color = fill_rect ? fill_color : mem_wdata[15:0];
   
   always @(posedge clk) begin
      if(fill_rect || (io_wstrb && sel_dat && mem_busy)) begin
	 /* verilator lint_off CASEINCOMPLETE */	 
	 case(MODE)
	   MODE_320x200x16bpp: begin
	      case(window_pixel_address[0])
	        1'b0: VRAM[window_pixel_address[15:1]][15:0 ] <= pixel_color;
	        1'b1: VRAM[window_pixel_address[15:1]][31:16] <= pixel_color;
	      endcase
	   end
	   MODE_320x200x8bpp: begin
	      case(window_pixel_address[1:0])
                2'b00: VRAM[window_pixel_address[16:2]][ 7:0 ] <= pixel_color[7:0];
                2'b01: VRAM[window_pixel_address[16:2]][15:8 ] <= pixel_color[7:0];
                2'b10: VRAM[window_pixel_address[16:2]][23:16] <= pixel_color[7:0];
                2'b11: VRAM[window_pixel_address[16:2]][31:24] <= pixel_color[7:0];		  
	      endcase
	   end
	   MODE_640x400x4bpp: begin
	      case(window_pixel_address[2:0])
                3'b000: VRAM[window_pixel_address[17:3]][ 3:0 ] <= pixel_color[3:0];
                3'b001: VRAM[window_pixel_address[17:3]][ 7:4 ] <= pixel_color[3:0];
                3'b010: VRAM[window_pixel_address[17:3]][11:8 ] <= pixel_color[3:0];
                3'b011: VRAM[window_pixel_address[17:3]][15:12] <= pixel_color[3:0];
                3'b100: VRAM[window_pixel_address[17:3]][19:16] <= pixel_color[3:0];
                3'b101: VRAM[window_pixel_address[17:3]][23:20] <= pixel_color[3:0];
                3'b110: VRAM[window_pixel_address[17:3]][27:24] <= pixel_color[3:0];
                3'b111: VRAM[window_pixel_address[17:3]][31:28] <= pixel_color[3:0];		   		   
	      endcase
	   end 
	 endcase 
	 /* verilator lint_on CASEINCOMPLETE */	 	 
      end else if(sel && !mem_busy) begin
	 if(mem_wmask[0]) VRAM[vram_word_address][ 7:0 ] <= mem_wdata[ 7:0 ];
	 if(mem_wmask[1]) VRAM[vram_word_address][15:8 ] <= mem_wdata[15:8 ];
	 if(mem_wmask[2]) VRAM[vram_word_address][23:16] <= mem_wdata[23:16];
	 if(mem_wmask[3]) VRAM[vram_word_address][31:24] <= mem_wdata[31:24];	 
      end 
   end
   
endmodule
	   
