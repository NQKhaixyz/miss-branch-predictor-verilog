# Kịch bản demo

1. Chạy mô phỏng nhanh cho vòng tính tổng và kiểm tra phục hồi. Lệnh tạo waveform predictor độc lập và hai waveform CPU cho mỗi chương trình.

   ```powershell
   python run.py --case sum_loop --case hazards_flush --no-sweep --no-plot --output build/demo
   ```

2. Mở `predictor_unit.vcd`. Trong scope `tb_predictor`, thêm `state_a[1:0]`, `update_taken`, `update_valid`, `raw_1`, `raw_2`, `hit_2` và `next_2`. Quan sát các mốc sau của bộ đếm 2 bit tại PC `0x100`.

   | Thời điểm | Trạng thái và ý nghĩa |
   |---|---|
   | 20 ns | Sau khi nhả reset, bộ đếm ở `01`, BTB miss và PC kế tiếp là `0x104` |
   | 35 ns | Cập nhật nhánh rẽ đưa bộ đếm lên `10`. BTB hit và trả đích `0x80` |
   | 45 ns | Lần rẽ tiếp theo đưa bộ đếm lên `11` |
   | 65 ns | Một lần không rẽ đưa bộ đếm về `10`. Bộ 2 bit vẫn đoán rẽ, bộ 1 bit đổi hướng |
   | 75 ns | Lần không rẽ tiếp theo đưa bộ đếm về `01`. Bộ 2 bit chuyển sang đoán không rẽ |

3. Mở `build/demo/metrics.csv` và chỉ ra `sum_loop` giảm từ 508 xuống 312 chu kỳ. Cả hai thực thi 304 lệnh và ghi kết quả 5.050 vào địa chỉ byte 2.048. Bộ 2 bit đúng 98/100 nhánh. Mở waveform của vòng tính tổng.

   ```powershell
   gtkwave build/demo/waveforms/sum_loop_two_bit.vcd
   ```

   Trong scope `tb_cpu`, thêm `clk`, `imem_addr`, `branch_valid`, `branch_pc`, `pred_btb_hit`, `pred_next_pc`, `actual_next_pc` và `flush`. Đặt các bus địa chỉ ở dạng hex.

   | Thời điểm | Điều thấy trên waveform |
   |---|---|
   | 75 ns | Nhánh `0x10` đoán `0x14`, kết quả đúng là `0x08`. `flush=1` |
   | 125 ns | Nhánh `0x10` dùng BTB để đoán đúng `0x08`. `flush=0` |

4. Mở `hazards_flush_two_bit.vcd` và thêm `dmem_we`, `dmem_addr`, `dmem_wdata`. Tại 55 ns, nhánh `0x08` yêu cầu sửa từ `0x0c` về `0x14`. Ở cạnh lên 65 ns, `imem_addr` chuyển sang `0x14`. Store trên đường sai không ghi vào `0x7fc`.
5. Dùng [báo cáo](../results/REPORT.md) để so sánh vòng lặp lồng, nhánh xen kẽ và ca trùng chỉ số. Giải thích vì sao tỷ lệ đúng hướng và mức tăng tốc thay đổi theo chương trình.

Waveform hoàn chỉnh đã có sẵn trong [results/waveforms](../results/waveforms/).
