# 06 — Câu hỏi phỏng vấn

> Project này chỉ có giá trị nếu bạn trả lời trôi chảy những câu dưới đây. Tự trả lời **thành lời, không nhìn giấy**, trước khi nộp CV. Nếu có câu nào ấp úng — quay lại [04-CONCEPTS.md](04-CONCEPTS.md).

---

## Nhóm 1 — Về video

**Q: Vì sao em dùng UDP mà không dùng TCP cho video?**
> Video thời gian thực thà mất dữ liệu còn hơn trễ dữ liệu. TCP truyền lại gói mất và chặn mọi gói sau đó (head-of-line blocking) — nghĩa là video sẽ đứng hình rồi tua nhanh. Còn gói của frame #5 mà đến sau khi frame #10 đã hiển thị thì cũng vô dụng. UDP cho phép bỏ gói và đi tiếp.

**Q: Vậy UDP không đảm bảo thứ tự, em xử lý thế nào?**
> RTP nằm trên UDP, thêm sequence number và timestamp. `rtpjitterbuffer` dùng chúng để sắp xếp lại gói và bù jitter. RTP không đảm bảo gì, nó chỉ cho receiver đủ thông tin để tự quyết định.

**Q: `rtpjitterbuffer latency` em đặt bao nhiêu, vì sao?**
> Em đặt 0. Nó là đánh đổi trực tiếp giữa độ trễ và độ mượt: buffer 200ms mặc định cộng thẳng 200ms vào latency, đổi lại chịu được jitter. Với FPV drone, người lái cần phản hồi tức thì nên chọn 0 và chấp nhận giật khi mạng xấu. Netflix thì chọn ngược lại, buffer vài giây.

**Q: ★ `tune=zerolatency` thực chất tắt cái gì?**
> Câu trả lời phổ biến là "tắt B-frame", nhưng với `x264enc` của GStreamer thì sai: element này mặc định `bframes=0`, không có B-frame nào để tắt. Em có đo. Nó tắt hai thứ khác: `rc-lookahead` (mặc định 40 frame — encoder giữ 40 frame để rate control nhìn trước, tốn đúng 40 frame độ trễ), và **frame-based multithreading** (mỗi luồng ôm một frame, nên trễ thêm khoảng một frame cho mỗi luồng — em đo được 28 frame trên máy 16 lõi). `zerolatency` đặt lookahead về 0 và chuyển sang sliced threads. Latency encoder xuống từ 2067 ms còn 4,2 ms.

**Q: Vậy `speed-preset=ultrafast` có đủ không?**
> Không. Preset đó có đặt `rc-lookahead=0`, nhưng không đụng tới frame threading — một mình nó chỉ xuống được 734 ms. Phải có `tune=zerolatency` mới hết phần threading.

**Q: Em làm sao biết B-frame không phải thủ phạm?**
> Em ép `threads=1` rồi đo riêng từng nút. Với `rc-lookahead=40` thì trễ đúng 39,4 frame; hạ lookahead về 0 thì còn 3,6 frame. Rồi giữ lookahead=0 và tăng số luồng: 4 luồng ra 10 frame, 8 luồng ra 14. Hai nguồn trễ tách bạch, cộng lại đúng bằng tổng đo được. Nếu B-frame có phần trong đó thì các con số này không khớp.

**Q: ★ Mất một gói UDP thì hình hỏng bao lâu?**
> Không phải một frame — mà đến tận keyframe tiếp theo. P-frame chỉ lưu phần khác biệt so với frame trước, nên khi một frame sai, mọi P-frame sau nó thừa kế lỗi và lỗi tích luỹ dần. Chỉ khi I-frame kế tiếp đến, hình mới hồi phục hoàn toàn. Em đặt `key-int-max=30` ở 30fps, nên tệ nhất là khoảng một giây. Em có screenshot thí nghiệm này, chạy `tc netem` với 2% packet loss.

**Q: Vậy giảm `key-int-max` xuống là xong?**
> Hồi phục nhanh hơn, nhưng I-frame to hơn P-frame cả chục lần nên bitrate tăng. Đó là đánh đổi giữa khả năng chống lỗi và băng thông, phải chọn theo chất lượng đường truyền.

**Q: Em đo latency bằng cách nào?**
> `GST_TRACERS="latency(flags=pipeline+element)"` — nó cho latency tổng và latency từng element, nên em biết ai là thủ phạm. Em có bảng so sánh 4 cấu hình trong `results/latency.md`, mỗi dòng kèm giải thích vì sao con số giảm.

**Q: Thay đổi nào giảm latency nhiều nhất?**
> Encoder, không phải chuyện gì gần mạng cả. Tổng đường ống đi từ 2288 ms xuống 7,8 ms, trong đó riêng `tune=zerolatency` gánh 2064 ms. Jitter buffer bớt 200 ms, `sync=false` bớt 15 ms. Em từng đoán `sync=false` mới là lớn nhất — đo xong mới biết mình sai một trăm lần về độ lớn.

**Q: ★ `sync=false` bớt có 15 ms, sao vẫn đáng làm?**
> Vì chỗ nó hiện ra không phải chỗ nó gây hại. Khi `sync=true`, sink giữ mỗi buffer tới đúng PTS mới nhả. Sink nghẽn thì các element phía trên dồn ứ lại phía sau nó — và trace cho thấy đống buffer đó nằm trong **jitter buffer**: đóng góp của jitter buffer rơi từ 15,5 ms xuống 0,8 ms khi em tắt sync. Element báo triệu chứng không phải element có bệnh. Đây là bài học em nhớ nhất từ project này.

**Q: Em dùng `gst-launch` hay tự viết app?**
> Em dùng `gst-launch` để dựng và hiểu pipeline trước, rồi viết receiver bằng C++ với GStreamer C API, lấy frame qua `appsink`, build bằng CMake. Code ở `video/src/receiver.cpp`.

**Q: `appsink` để làm gì, sao không dùng `autovideosink`?**
> `autovideosink` vẽ lên màn hình rồi hết. `appsink` đưa từng frame vào code C++ của em — em đọc `GST_BUFFER_PTS` và đếm frame. Ngoài đời đây chính là chỗ cắm AI inference vào: frame ra khỏi `appsink` rồi đẩy sang TensorRT.

**Q: Em có gặp memory leak không?**
> Có rủi ro ở chuỗi ref/unref của GStreamer — mỗi `pull_sample` phải `gst_sample_unref`, mỗi `buffer_map` phải `buffer_unmap`. Quên là RAM tăng dần tới khi bị OOM kill. Em chạy `valgrind --leak-check=full` để kiểm tra, kết quả lưu trong `results/`.

**Q: Project này chạy trên Jetson thì đổi gì?**
> `videotestsrc` → `nvarguscamerasrc`, `videoconvert` → `nvvidconv`, `x264enc` → `nvv4l2h264enc` để dùng NVENC. Phần `rtph264pay`, `udpsink`, jitter buffer và receiver C++ giữ nguyên. Encoder cứng giảm tải CPU và giảm latency encode, nhưng kiến trúc pipeline không đổi.

---

## Nhóm 2 — Về MAVLink

**Q: MAVLink là gì?**
> Một giao thức nhị phân để phần mềm nói chuyện với flight controller. Nó là protocol, không phải thư viện — `pymavlink` và MAVSDK là hai implementation khác nhau. Header nhỏ, có checksum, chạy trên bất kỳ transport nào: UART, UDP, TCP, radio. Nên companion computer nối FC qua UART còn em test qua UDP mà code không đổi.

**Q: Heartbeat để làm gì?**
> Mọi node phát heartbeat ở 1Hz, mang flight mode và cờ armed. Quy ước là mất 3 nhịp liên tiếp — khoảng 3 giây — thì coi như đứt link và vehicle kích hoạt failsafe, thường là RTL. Gateway của em có watchdog theo đúng ngưỡng đó. Đây là logic an toàn bay, không phải chi tiết trang trí.

**Q: Trình tự cất cánh của em thế nào?**
> Set mode GUIDED, chờ EKF hội tụ và có GPS lock, arm bằng `MAV_CMD_COMPONENT_ARM_DISARM`, rồi `MAV_CMD_NAV_TAKEOFF` với độ cao ở param7. Sai thứ tự là FC từ chối.

**Q: Vì sao phải GUIDED trước?**
> Ở STABILIZE hay LOITER, FC nghe người lái cầm remote. GUIDED là mode nói "tôi nhận lệnh từ phần mềm". Arm khi chưa GUIDED, hoặc takeoff khi chưa arm, thì FC trả `MAV_RESULT_DENIED`.

**Q: Em có kiểm tra lệnh thành công không?**
> Có, em đọc `COMMAND_ACK`. Bắn lệnh rồi cho là xong là sai — FC có pre-arm check và sẽ từ chối nếu EKF chưa sẵn sàng. Em phân biệt `ACCEPTED`, `TEMPORARILY_REJECTED` và `DENIED` để biết nên thử lại hay dừng.

**Q: Em không có drone thật, vậy test kiểu gì?**
> Em dùng ArduPilot SITL. Đó là chính firmware ArduPilot compile cho x86 thay vì ARM — chạy đủ EKF, controller, pre-arm check, mô phỏng vật lý. Giao thức, timing và hành vi từ chối lệnh đều thật. Kỹ sư drone dùng SITL để test hằng ngày, đây là quy trình chuẩn của ngành chứ không phải giải pháp chữa cháy.

**Q: Bẫy nào em gặp khi parse telemetry?**
> MAVLink gửi số nguyên đã scale để tiết kiệm băng thông. `lat`/`lon` là degE7 phải chia 1e7, `alt` là mm, `ATTITUDE.roll` là radian. Và `alt` là so với mực nước biển còn `relative_alt` mới là so với điểm cất cánh — muốn kiểm tra takeoff 10m phải nhìn `relative_alt`.

---

## Nhóm 3 — Câu khó, về giới hạn của project

Đây là nhóm quan trọng nhất. **Thành thật thắng nói quá.** Người phỏng vấn ghét nhất ứng viên phóng đại project của mình, và họ phát hiện ra trong ba câu hỏi.

**Q: Em có làm Yocto không?**
> Chưa. Trong 2 ngày em ưu tiên phần lõi của JD là video pipeline và MAVLink. Em hiểu Yocto là build system tạo distro Linux tuỳ biến qua layer và recipe, và BSP của Jetson dùng nó. Em sẵn sàng học.

**Q: Em chưa từng chạy trên Jetson thật, sao dám nói hiểu?**
> Đúng, em chưa có board. Nhưng kiến trúc pipeline không phụ thuộc phần cứng — em biết chính xác element nào phải đổi (`nvv4l2h264enc`, `nvvidconv`, `nvarguscamerasrc`) và vì sao. Cái em chưa làm được là đo latency thật của NVENC và xử lý DMA buffer giữa các element NVMM.

**Q: Điểm yếu lớn nhất của project là gì?**
> Cả hai đầu chạy trên loopback nên em không đo được latency của NIC thật, và không gặp các vấn đề của mạng thật như MTU hay congestion. Em bù bằng `tc netem` để giả lập loss và jitter, nhưng đó vẫn là mô phỏng.

**Q: Nếu có thêm một tuần em làm gì tiếp?**
> Ba việc, theo thứ tự: chạy trên Jetson thật để đo NVENC; đo glass-to-glass latency bằng camera quay màn hình thay vì chỉ đo pipeline latency; và làm phần chống rung bằng `vidstab` hoặc OpenCV vì đó là một trách nhiệm chính trong JD mà em mới chỉ demo bằng FFmpeg.

**Q: Em học được gì lớn nhất?**
> Rằng FPS và latency là hai chỉ số khác nhau. Lúc đầu em định đo FPS, nhưng buffer sâu cho FPS rất đẹp trong khi latency thảm hoạ. Chọn sai chỉ số là hiểu sai bài toán.

---

## Tự kiểm tra trước khi nộp CV

- `[ ]` Trả lời được **mọi** câu trên, thành lời, không nhìn giấy
- `[ ]` Mở được `receiver.cpp` và giải thích từng dòng
- `[ ]` `results/latency.md` có số thật, không phải số bịa
- `[ ]` README nêu rõ giới hạn của project (điểm cộng, không phải điểm trừ)
- `[ ]` Demo video 30–60 giây, chạy được ngay khi mở
