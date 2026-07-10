# 06 — Câu hỏi phỏng vấn

> Project này chỉ có giá trị nếu bạn trả lời trôi chảy những câu dưới đây. Tự trả lời **thành lời, không nhìn giấy**, trước khi nộp CV. Nếu có câu nào ấp úng — quay lại [04-CONCEPTS.md](04-CONCEPTS.md).

---

## Nhóm 1 — Về video

**Q: Vì sao em dùng UDP mà không dùng TCP cho video?**
> Video thời gian thực thà mất dữ liệu còn hơn trễ dữ liệu. TCP truyền lại gói mất và chặn mọi gói sau đó (head-of-line blocking) — nghĩa là video sẽ đứng hình rồi tua nhanh. Còn gói của frame #5 mà đến sau khi frame #10 đã hiển thị thì cũng vô dụng. UDP cho phép bỏ gói và đi tiếp.

**Q: Vậy UDP không đảm bảo thứ tự, em xử lý thế nào?**
> RTP nằm trên UDP, thêm sequence number và timestamp. `rtpjitterbuffer` dùng chúng để sắp xếp lại gói và bù jitter. RTP không đảm bảo gì, nó chỉ cho receiver đủ thông tin để tự quyết định.

**Q: `rtpjitterbuffer latency` em đặt bao nhiêu, vì sao?**
> Em đặt 0 để đo latency thấp nhất, nhưng em đã đo cả cái giá của nó nên em sẽ không đặt 0 trên drone thật. Nó là đánh đổi trực tiếp: buffer 200ms cộng thẳng 200ms vào latency, đổi lại chịu được jitter. Netflix chọn buffer vài giây, FPV chọn nhỏ. Nhưng "nhỏ" không phải là "không".

**Q: ★ Cái giá của `latency=0` là bao nhiêu?**
> Em đo bằng một control rất sạch: cho mạng jitter ±5 ms mà **không mất gói nào**. Kernel không đánh rơi gói nào — em kiểm bằng `tc -s qdisc`. Vậy mà receiver chỉ giải mã được **67 trên 300 frame**. 3495 gói đến nơi nguyên vẹn và bị chính jitter buffer vứt đi vì "đến muộn": netem cho mỗi gói một độ trễ ngẫu nhiên 20±5 ms, thế là các gói gửi cách nhau vài micro giây bị đảo thứ tự, mà buffer sâu 0 thì không có chỗ nào để giữ gói đến sớm. Bật `latency=200` lên thì 270–300/300 frame. Nói gọn: `latency=0` không chịu nổi một *mạng*, nó chỉ chịu nổi một *sợi dây*. Trên drone em sẽ đặt buffer bằng khoảng 1–2 lần jitter đo được của link, chứ không đặt 0.

**Q: ★ `tune=zerolatency` thực chất tắt cái gì?**
> Câu trả lời phổ biến là "tắt B-frame", nhưng với `x264enc` của GStreamer thì sai: element này mặc định `bframes=0`, không có B-frame nào để tắt. Em có đo. Nó tắt hai thứ khác: `rc-lookahead` (mặc định 40 frame — encoder giữ 40 frame để rate control nhìn trước, tốn đúng 40 frame độ trễ), và **frame-based multithreading** (mỗi luồng ôm một frame, nên trễ thêm khoảng một frame cho mỗi luồng — em đo được 28 frame trên máy 16 lõi). `zerolatency` đặt lookahead về 0 và chuyển sang sliced threads. Latency encoder xuống từ 2067 ms còn 4,2 ms.

**Q: Vậy `speed-preset=ultrafast` có đủ không?**
> Không. Preset đó có đặt `rc-lookahead=0`, nhưng không đụng tới frame threading — một mình nó chỉ xuống được 734 ms. Phải có `tune=zerolatency` mới hết phần threading.

**Q: Em làm sao biết B-frame không phải thủ phạm?**
> Em ép `threads=1` rồi đo riêng từng nút. Với `rc-lookahead=40` thì trễ đúng 39,4 frame; hạ lookahead về 0 thì còn 3,6 frame. Rồi giữ lookahead=0 và tăng số luồng: 4 luồng ra 10 frame, 8 luồng ra 14. Hai nguồn trễ tách bạch, cộng lại đúng bằng tổng đo được. Nếu B-frame có phần trong đó thì các con số này không khớp.

**Q: ★ Mất một gói UDP thì hình hỏng bao lâu?**
> Đến tận keyframe tiếp theo, không phải một frame. P-frame chỉ lưu phần khác biệt so với frame trước, nên một frame sai là mọi P-frame sau nó sai theo. Em đo chứ không suy luận: so từng pixel với luồng gốc, **10 trên 10 đợt hỏng kết thúc đúng tại một keyframe**, không lệch một frame nào. Và sai lệch **không phai dần** — nó phẳng lì ở mức 22,6 (mean abs diff) suốt cả GOP rồi rơi về 0,3 đúng tại IDR, vì P-frame chép nguyên khối sai từ frame trước. `key-int-max=30` ở 30fps, nên tệ nhất là 1000 ms.

**Q: Vậy trung bình mất một gói hỏng nửa GOP, tức 15 frame?**
> Đó là câu trả lời sách vở và nó **sai**. Gói mất phân bố đều theo *gói*, không phải theo *frame*. Mà keyframe của luồng em to gấp 15 lần P-frame, chiếm **15% tổng số gói**. Trúng một gói của keyframe là mất trọn 30 frame. Tính lại theo phân bố gói thật thì kỳ vọng là 17,6 frame. Đo thực tế còn cao hơn, 24,1 frame mỗi GOP bị trúng — vì ở tỉ lệ mất gói thật, một GOP hỏng thường trúng nhiều hơn một lần và thiệt hại tính từ lần sớm nhất. Em có mô phỏng Monte Carlo trên đúng layout gói của luồng đó để kiểm tra: mô hình nói 61% GOP hỏng, đo được 55%.

**Q: Vậy giảm `key-int-max` xuống là xong?**
> Hồi phục nhanh hơn, nhưng bitrate tăng vì I-frame to. Cẩn thận chỗ này: "I-frame to gấp chục lần P-frame" là phát biểu về *nội dung*, không phải về H.264. Cùng encoder, cùng bitrate, em đo được 2,8× với ảnh tĩnh, 3,2× với vật thể nhỏ chuyển động, 15,0× với cảnh động kín khung. Muốn biết đánh đổi thật thì phải đo trên chính cảnh quay của mình.

**Q: ★ Ứng dụng của em có biết là đang mất gói không?**
> Không, và đây là thứ em học được nhiều nhất. Em từng viết trong `receiver.cpp` rằng `GST_BUFFER_FLAG_DISCONT` là dấu vân tay của mất gói. Sai. Em quét từ 0% đến 20% packet loss: ở 20%, 474 gói không tới nơi, ứng dụng vẫn nhận 148/150 frame, `discont` = 0, `CORRUPTED` = 0. `avdec_h264` che lỗi trong im lặng và trả về một frame trông y như frame tốt. Muốn biết link đang xấu thì **phải đếm ở tầng RTP** — em đọc property `stats` của `rtpjitterbuffer`, lấy `num-lost`. Một cái đèn "video OK" dựa trên số frame sẽ báo xanh trong khi phi công đang nhìn màn hình vỡ nát.
>
> *Nếu bị vặn "nhưng `CORRUPTED` có tồn tại mà":* có, và nó **có** bật — em thấy 19/42 frame khi mạng tệ tới mức mỗi picture mất gần hết slice. Nhưng lúc đó video đã hỏng từ lâu. Nó không phân biệt nổi link sạch với link mất 1/5 số gói, nên không dùng làm tín hiệu sức khoẻ được. `DISCONT` thì không bật lần nào, trong mọi thí nghiệm.

**Q: Sao em tin con số `num-lost` đó?**
> Vì em đối chiếu với `tc -s qdisc show dev lo`, tức bộ đếm của kernel. Trên link chỉ mất gói, hai bên khớp từng gói: netem rơi 101, `num-lost` báo 101. Nhưng khi bật jitter cho gói đảo thứ tự thì `num-lost` vọt lên 3640 trong khi 4580 gói vẫn được đẩy đi và 270/300 frame vẫn giải mã được — nó đang đếm *số lần phát hiện khoảng trống*, không phải *số gói mất*. Nếu em chỉ nhìn một bộ đếm, em đã báo cáo con số 3640 đó.

**Q: Em hiển thị frame vỡ hay không hiển thị gì?**
> Đó là một lựa chọn thật, không phải mặc định trời cho. `rtph264depay wait-for-keyframe=true` thì sau khi mất gói nó không trả frame nào cho tới keyframe sạch tiếp theo. Em đo cả hai: ở 2% loss, chế độ che lỗi giao đủ 300/300 frame nhưng nhiều frame vỡ; chế độ chờ keyframe chỉ giao **11/300 frame** — màn hình đứng hình gần như suốt. Không chế độ nào tốt, chúng chỉ tệ theo cách khác nhau. Với drone em nghiêng về che lỗi, vì một khung hình đứng yên trông *sạch sẽ* lại nguy hiểm hơn khung hình vỡ: phi công không biết là nó cũ.

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
> Cả hai đầu chạy trên loopback nên em không đo được latency của NIC thật, và không gặp MTU hay congestion. Em bù bằng `tc netem`, nhưng `netem loss X%` sinh lỗi **độc lập từng gói**, còn sóng vô tuyến thật mất gói theo **chùm**. Mất 20 gói liên tiếp phá hỏng cả một keyframe; mất 20 gói rải rác thì decoder che được gần hết. Mọi con số packet-loss của em đều nằm dưới giả định độc lập đó, và em nói rõ điều này ngay đầu `results/packet-loss.md`.

**Q: Em có định lượng được sự khác biệt giữa hai kiểu mất gói không?**
> Chưa đo, nhưng em biết cách: `netem` có `loss gemodel` (mô hình Gilbert-Elliott) để sinh lỗi theo chùm. Nếu có thêm thời gian đó là thí nghiệm tiếp theo, vì kết luận "15% số gói thuộc keyframe" gợi ý rằng chùm lỗi rơi trúng keyframe sẽ tệ hơn hẳn phân bố đều.

**Q: Nếu có thêm một tuần em làm gì tiếp?**
> Ba việc, theo thứ tự: chạy trên Jetson thật để đo NVENC; đo glass-to-glass latency bằng camera quay màn hình thay vì chỉ đo pipeline latency; và làm phần chống rung bằng `vidstab` hoặc OpenCV vì đó là một trách nhiệm chính trong JD mà em mới chỉ demo bằng FFmpeg.

**Q: Em học được gì lớn nhất?**
> Rằng một bộ đếm chưa đối chiếu thì chưa phải số liệu. Ba lần trong project này em suýt báo cáo con số sai mà vẫn thấy hợp lý: `discont` bằng 0 vì em tưởng nó bắt được mất gói (thật ra nó không bao giờ bật); một cột latency của `fakesink` mà thật ra element đó không hề sinh bản ghi nào; và `num-lost` = 3640 trên một link chỉ mất 90 gói. Cả ba đều bị bắt bằng cách đo lại bằng dụng cụ thứ hai, độc lập. Bài học thứ hai: FPS và latency là hai chỉ số khác nhau — buffer sâu cho FPS đẹp trong khi latency thảm hoạ.

**Q: Kể một lỗi thí nghiệm em tự phát hiện.**
> Em muốn chụp ảnh so sánh "hình sạch" và "hình vỡ", nên chạy hai lần: một lần link sạch làm tham chiếu, một lần mất gói. So pixel thì **cả 300 frame đều khác nhau**, kể cả khi so hai lần chạy sạch với nhau. Hoá ra `x264enc` **không bit-reproducible**: cùng một input tất định, encode hai lần ra hai file khác nhau (em kiểm bằng `md5sum`). Vậy là em đang so hai bitstream khác nhau chứ không so hai điều kiện mạng. Cách sửa: encode **một lần** ra file, rồi phát lại đúng file đó qua RTP cho cả hai lần chạy. Sau đó control cho ra 600/600 frame trùng khít từng bit, và mọi sai khác còn lại chắc chắn là do mạng. Trước đó em còn dùng ảnh tĩnh SMPTE và không thấy hình vỡ ở đâu cả — vì decoder che lỗi bằng cách chép khối từ frame trước, mà với ảnh tĩnh thì khối đó *đúng*. Camera trên drone không bao giờ đứng yên, nên em đổi sang cảnh động.

---

## Tự kiểm tra trước khi nộp CV

- `[ ]` Trả lời được **mọi** câu trên, thành lời, không nhìn giấy
- `[ ]` Mở được `receiver.cpp` và giải thích từng dòng
- `[ ]` `results/latency.md` có số thật, không phải số bịa
- `[ ]` README nêu rõ giới hạn của project (điểm cộng, không phải điểm trừ)
- `[ ]` Demo video 30–60 giây, chạy được ngay khi mở
