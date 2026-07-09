# 04 — Mọi khái niệm, giải thích từ đầu

> File này tồn tại để đạt mục tiêu: **hiểu 90–100% project**. Đọc trước khi code, tra lại khi gặp element lạ. Mỗi mục ngắn gọn, nhưng đủ để bạn giải thích lại cho người khác nghe.

---

# PHẦN A — GStreamer

## A1. Mô hình tư duy: pipeline, element, pad, caps

GStreamer là một **dây chuyền lắp ráp**. Dữ liệu chảy từ trái sang phải qua từng trạm.

- **Element** — một trạm. `x264enc` là một element. Nó có input và output.
- **Pad** — cổng của element. Element có `sink pad` (đầu vào) và `src pad` (đầu ra). Tên hơi ngược trực giác: "src" là chỗ dữ liệu *đi ra*.
- **Caps** (capabilities) — mô tả dữ liệu đi qua pad: format, độ phân giải, framerate. Ví dụ `video/x-raw,width=1280,height=720,framerate=30/1`.
- **Pipeline** — cả dây chuyền, cộng thêm bus để báo lỗi và clock để đồng bộ.
- **Caps negotiation** — khi bạn nối `A ! B`, hai element **tự thương lượng** xem truyền định dạng nào. Nếu không có định dạng chung → lỗi `not-negotiated`.

Ký hiệu `!` trong `gst-launch` chính là "nối src pad của cái bên trái vào sink pad của cái bên phải".

## A2. Vì sao `udpsrc` phải khai `caps` thủ công

Caps negotiation chỉ hoạt động khi hai element **nằm cùng một tiến trình**. Gói UDP tới từ mạng chỉ là một đống byte — `udpsrc` không có cách nào biết đó là H.264 hay Opus hay rác.

Nên ta phải nói cho nó biết:
```
caps="application/x-rtp,media=video,encoding-name=H264,payload=96"
```

`payload=96` là **payload type động**. RTP dành số 96–127 cho các codec không có số cố định. Sender khai `pt=96`, receiver phải khai đúng `96`. Lệch số → không nhận được gì, và **không có thông báo lỗi** — pipeline chạy im lặng, màn hình đen. Đây là lỗi kinh điển.

## A3. `videotestsrc` và `is-live=true`

Nguồn video giả lập. `pattern=smpte` cho ra sọc màu, `pattern=ball` cho quả bóng chạy (dễ thấy giật hình).

`is-live=true` khiến nó hành xử như camera thật: sinh frame theo **thời gian thực**, không sinh nhanh hết mức có thể. Thiếu cờ này, pipeline chạy nhanh hơn 30fps và mọi phép đo latency trở nên vô nghĩa.

## A4. `x264enc` và `tune=zerolatency`

H.264 encoder phần mềm. Ba tham số cần hiểu:

**`tune=zerolatency`** — tắt hai thứ:
- **B-frame** (bi-directional frame). B-frame nén rất tốt vì nó tham chiếu *cả frame trước lẫn frame sau*. Nhưng để mã hoá nó, encoder phải **chờ frame tương lai đến** → tự động thêm độ trễ bằng vài frame. Với video call/drone, đây là thứ đầu tiên phải tắt.
- **Lookahead** — encoder nhìn trước N frame để phân bổ bitrate thông minh. Cũng cần chờ → cũng phải tắt.

**`speed-preset=ultrafast`** — đổi chất lượng nén lấy tốc độ CPU. Encode nhanh hơn = latency thấp hơn = file to hơn.

**`key-int-max=30`** — cứ tối đa 30 frame thì chèn một keyframe. Ở 30fps nghĩa là **1 giây một keyframe**. Xem A7 để hiểu vì sao con số này quyết định video vỡ bao lâu khi mất gói.

## A5. H.264: I-frame, P-frame, GOP

- **I-frame** (keyframe) — một tấm ảnh hoàn chỉnh, tự giải mã được, không cần frame nào khác. To.
- **P-frame** — chỉ lưu **phần khác biệt** so với frame trước. Nhỏ hơn I-frame cả chục lần.
- **GOP** (Group of Pictures) — một I-frame và tất cả P-frame phụ thuộc vào nó. `key-int-max=30` → GOP dài 30 frame.

Đây là lý do video nén được: trong 30 frame liên tiếp, phần lớn pixel không đổi.

## A6. `rtph264pay` và `config-interval=1`

Chia H.264 stream thành gói RTP vừa MTU (~1400 byte), gắn **sequence number** và **timestamp** vào mỗi gói.

`config-interval=1` = cứ mỗi 1 giây, gửi lại **SPS/PPS** (Sequence/Picture Parameter Set) — hai gói metadata mô tả độ phân giải, profile, level. Decoder **không thể giải mã bất cứ thứ gì** trước khi nhận được SPS/PPS.

Nếu không đặt `config-interval`, SPS/PPS chỉ gửi **một lần lúc bắt đầu**. Receiver khởi động sau sender → mất SPS/PPS → màn hình đen vĩnh viễn. Với livestream, luôn đặt `config-interval=1`.

## A7. ★ Vì sao mất một gói UDP lại hỏng hình cả giây

Đây là câu hỏi phỏng vấn kinh điển, và là lý do tồn tại của thí nghiệm `tc netem`.

Giả sử mất một gói thuộc frame #5, và GOP dài 30 frame (I-frame ở #0 và #30):

1. Frame #5 giải mã sai → hình vỡ.
2. Frame #6 là P-frame, nó nói "giống frame #5, thêm chút thay đổi". Nhưng #5 đã sai → #6 sai theo.
3. Frame #7 tham chiếu #6 → sai tiếp. Lỗi **lan truyền và tích luỹ**.
4. Đến frame #30 — một I-frame mới, tự giải mã được → hình **hồi phục hoàn toàn**.

Vậy mất **1 gói** làm hỏng **25 frame ≈ 0.83 giây**. Cái hồi phục hình không phải là frame tiếp theo, mà là **keyframe tiếp theo**.

**Hệ quả thiết kế:** giảm `key-int-max` → hồi phục nhanh hơn, nhưng tốn bitrate hơn (I-frame to). Đây là một đánh đổi thật mà kỹ sư video phải chọn hằng ngày.

## A8. `rtpjitterbuffer` — đánh đổi cốt lõi

Gói UDP đến **không đúng thứ tự** và **không đều nhịp** (jitter). Jitter buffer giữ gói lại một lúc, sắp xếp theo sequence number, rồi nhả ra đều đặn.

- `latency=200` (mặc định) → giữ gói 200ms. Mượt, chịu được jitter, nhưng **cộng thẳng 200ms vào độ trễ**.
- `latency=0` → nhả ngay. Trễ thấp nhất, nhưng gói đến trễ/lệch thứ tự sẽ bị **vứt bỏ** → giật hình.

Đây là **đánh đổi trung tâm của cả project**: latency ↔ độ mượt. Không có đáp án đúng, chỉ có đáp án phù hợp use-case. Drone FPV chọn `latency=0`. Xem phim Netflix chọn buffer vài giây.

## A9. `sync=false` trên sink

Mặc định, sink nhìn **PTS** (Presentation Timestamp) của mỗi frame và **chờ đến đúng thời điểm đó** mới hiển thị — để video khớp với audio và chạy đúng tốc độ.

Với livestream không có audio, việc chờ đó là **độ trễ thuần tuý vô ích**. `sync=false` = "có frame là vẽ ngay".

Đây thường là thay đổi **một dòng cho hiệu quả lớn nhất** trong toàn bộ việc tuning latency. Rất nhiều người tune encoder cả buổi mà quên dòng này.

## A10. `appsink` — cầu nối GStreamer ↔ code C++

`autovideosink` vẽ lên màn hình rồi hết. `appsink` thì **đưa từng frame vào tay code của bạn**.

Cơ chế:
1. Đặt `emit-signals=true` trên appsink.
2. Nối callback vào signal `new-sample`.
3. Trong callback: `gst_app_sink_pull_sample()` → `GstSample` → `GstBuffer`.
4. `gst_buffer_map()` để lấy con trỏ vào pixel data. **Bắt buộc `gst_buffer_unmap()`** sau đó.
5. `GST_BUFFER_PTS(buf)` cho timestamp.
6. `gst_sample_unref()` — nếu quên, **memory leak**, RAM tăng dần cho tới khi bị kill.

> JD ghi "debug các vấn đề về bộ nhớ". Chuỗi ref/unref của GStreamer chính là chỗ sinh ra memory leak trong đời thật. Chạy `valgrind --leak-check=full ./receiver` một lần và ghi kết quả vào `results/` — đó là bằng chứng bạn hiểu điều này.

Đây cũng là chỗ ngoài đời bạn cắm AI inference vào: frame ra khỏi `appsink` → đẩy sang TensorRT/ONNX → vẽ bounding box.

## A11. `GST_TRACERS` — cách đo latency đúng

Không cần viết code đo. GStreamer có sẵn:

```bash
GST_DEBUG="GST_TRACER:7" GST_TRACERS="latency(flags=pipeline+element)" gst-launch-1.0 ...
```

- `pipeline` → tổng latency từ source tới sink.
- `element` → latency của **từng element**, để biết ai là thủ phạm.

Kết quả in ra stderr, `2>&1 | tee results/trace.log` để lưu lại.

Cái này ăn đứt việc chạy `top` trong vòng lặp: nó là công cụ mà kỹ sư GStreamer thật sự dùng, và nó cho ra **số liệu quy trách nhiệm được**.

## A12. `tc netem` — giả lập mạng xấu

`tc` (traffic control) là công cụ của Linux kernel để định hình traffic. `netem` là module giả lập mạng.

```bash
sudo tc qdisc add dev lo root netem loss 2% delay 20ms 5ms
#                                      ↑        ↑       ↑
#                              mất 2% gói   trễ 20ms  jitter ±5ms
sudo tc qdisc del dev lo root    # tắt
```

Chạy trên `lo` (loopback) thì ảnh hưởng **toàn bộ** traffic loopback của máy — kể cả thứ khác. Nhớ `del` sau khi đo.

Không có công cụ này, "low latency over Ethernet" chỉ là chữ. Có nó, bạn chứng minh được mình hiểu vì sao UDP + RTP tồn tại.

## A13. Mapping sang Jetson Orin NX

Nói được câu này trong phỏng vấn là ghi điểm lớn, dù bạn chưa từng sờ vào board:

| Trên PC (project này) | Trên Jetson |
|---|---|
| `videotestsrc` | `nvarguscamerasrc` (CSI) hoặc `v4l2src` (USB) |
| `videoconvert` | `nvvidconv` (convert bằng phần cứng) |
| `x264enc` | `nvv4l2h264enc` (NVENC — encoder cứng) |
| `avdec_h264` | `nvv4l2decoder` |

Phần `rtph264pay` / `udpsink` / `rtpjitterbuffer` / receiver C++ **giữ nguyên không đổi**.

Ý nghĩa: encoder phần cứng giải phóng CPU và giảm latency encode, nhưng **kiến trúc pipeline không đổi**. Học pipeline trên PC là học đúng thứ cần học.

---

# PHẦN B — Mạng

## B1. Vì sao video dùng UDP, không dùng TCP

TCP đảm bảo **không mất gói, đúng thứ tự**. Cách nó làm: gói nào mất thì **truyền lại**, và giữ mọi gói sau đó lại chờ (head-of-line blocking).

Với video thời gian thực, truyền lại là **vô nghĩa**: gói của frame #5 mà đến sau khi frame #10 đã hiển thị thì vứt đi thôi. Tệ hơn, việc chờ nó làm **mọi frame sau bị treo** → video đứng hình rồi tua nhanh.

Video thời gian thực thà **mất dữ liệu** còn hơn **trễ dữ liệu**. Đó chính xác là hợp đồng của UDP.

Đổi lại, UDP không cho bạn gì cả: không thứ tự, không phát hiện mất gói, không timestamp. Nên mới cần RTP.

## B2. RTP thêm gì lên trên UDP

RTP (Real-time Transport Protocol) là một header nhỏ nằm trong payload của UDP. Nó thêm:

- **Sequence number** — để receiver biết gói nào mất, gói nào đến sai thứ tự.
- **Timestamp** — thời điểm frame được lấy mẫu, để phát lại đúng nhịp.
- **Payload type** — cho biết đây là H.264 (96) hay codec khác.
- **SSRC** — định danh nguồn, để phân biệt nhiều stream trên cùng một port.

RTP **không** đảm bảo gì cả — nó chỉ **cung cấp đủ thông tin để receiver tự xử lý**. Chính jitter buffer là thứ dùng sequence number và timestamp đó.

Câu chốt: *"UDP nói 'tôi không hứa gì'. RTP nói 'nhưng tôi cho bạn biết cái gì đã mất.'"*

## B3. WSL2 networking — bẫy thực tế

WSL2 chạy trong một VM có **NAT riêng**. Địa chỉ IP của WSL không phải IP của Windows.

- Sender và receiver **cùng trong một distro WSL** → dùng `127.0.0.1`, chạy ngon, không cần cấu hình gì. **Project này chọn cách đó.**
- Sender trong WSL, receiver trên Windows → gói UDP không qua được nếu không cấu hình. Cần bật `networkingMode=mirrored` trong `%USERPROFILE%\.wslconfig` (Windows 11 22H2 trở lên).

Đừng phí thời gian vào cái này. Giữ cả hai đầu trong WSL.

---

# PHẦN C — MAVLink

## C1. MAVLink là gì

Một **giao thức nhị phân** để phần mềm nói chuyện với drone. Nó **không phải thư viện** — `pymavlink` là một implementation của nó, MAVSDK là một cái khác.

Đặc điểm: header nhỏ (~12 byte), có checksum, chạy được trên **bất kỳ transport nào** — UART, UDP, TCP, radio. Chính vì thế companion computer nối FC qua UART, còn ta test qua UDP, mà code không đổi.

## C2. Heartbeat và watchdog

Mọi thành phần trong hệ MAVLink phát `HEARTBEAT` ở **1Hz**. Heartbeat mang: system id, loại vehicle, **flight mode**, và cờ **armed**.

Quy ước ngành: **mất 3 heartbeat liên tiếp (~3 giây) thì coi như đứt link**, và vehicle phải kích hoạt failsafe (thường là RTL — return to launch).

Watchdog trong gateway không phải chi tiết trang trí. Nó là **logic an toàn bay**. Nói được điều này là bạn khác hẳn người chỉ chạy demo.

## C3. Message vs Command

Hai thứ khác nhau, hay bị lẫn:

- **Message** — dữ liệu phát liên tục, một chiều, không ai xác nhận. `ATTITUDE`, `GLOBAL_POSITION_INT`, `VFR_HUD`. Cứ chảy về đều đều.
- **Command** — gói `COMMAND_LONG` chứa một `MAV_CMD_*`, gửi lên, và FC **phải trả lời** bằng `COMMAND_ACK`.

Gateway **bắt buộc đọc `COMMAND_ACK`**. Bắn lệnh rồi cho là xong (fire-and-forget) là sai. FC có thể từ chối lệnh, và bạn cần biết vì sao:

| `COMMAND_ACK.result` | Nghĩa |
|---|---|
| `MAV_RESULT_ACCEPTED` | OK |
| `MAV_RESULT_TEMPORARILY_REJECTED` | chưa sẵn sàng, thử lại sau |
| `MAV_RESULT_DENIED` | điều kiện tiên quyết chưa thoả (chưa GUIDED, chưa arm...) |
| `MAV_RESULT_UNSUPPORTED` | FC không hỗ trợ lệnh này |

## C4. Trình tự arm → takeoff, và vì sao thứ tự đó

```
1. Set mode GUIDED       → FC chấp nhận nhận lệnh từ companion computer
2. Chờ EKF/GPS sẵn sàng  → SITL mất ~20–30 giây
3. Arm  (MAV_CMD_COMPONENT_ARM_DISARM = 400, param1=1)
4. Takeoff (MAV_CMD_NAV_TAKEOFF = 22, param7 = độ cao mét)
```

- Ở mode `STABILIZE`/`LOITER`, FC nghe **người lái cầm remote**, không nghe lệnh script. `GUIDED` là mode nói "tôi nhận lệnh từ phần mềm".
- Arm = cấp điện cho động cơ. FC **từ chối arm** nếu EKF chưa hội tụ hoặc chưa có GPS lock — đây là **pre-arm check**, tính năng an toàn, không phải bug.
- Takeoff khi chưa arm → `MAV_RESULT_DENIED`.

90% người mới sai ở đây: gửi arm rồi gửi takeoff ngay trong 100ms, không chờ ACK, không chờ EKF. Rồi kết luận "MAVLink không hoạt động".

## C5. Bẫy đơn vị — MAVLink gửi số nguyên đã scale

Để tiết kiệm băng thông, MAVLink không gửi float. Sai chỗ này là log ra rác:

| Trường | Đơn vị gửi đi | Đổi ra |
|---|---|---|
| `GLOBAL_POSITION_INT.lat` / `.lon` | `degE7` (int32) | `/ 1e7` → độ |
| `GLOBAL_POSITION_INT.alt` | mm (int32) | `/ 1000` → mét |
| `GLOBAL_POSITION_INT.relative_alt` | mm | `/ 1000` → mét trên mặt đất |
| `ATTITUDE.roll/pitch/yaw` | **radian** (float) | `* 180/π` → độ |
| `SYS_STATUS.voltage_battery` | mV | `/ 1000` → volt |
| `VFR_HUD.groundspeed` | m/s (float) | không đổi |

`alt` là độ cao so với mực nước biển (MSL). `relative_alt` là so với điểm cất cánh. Muốn kiểm tra takeoff 10m thì nhìn `relative_alt`, không phải `alt`.

## C6. SITL là gì

**S**oftware **I**n **T**he **L**oop. Chính firmware ArduPilot, compile cho x86 Linux thay vì cho ARM. Nó chạy đầy đủ EKF, controller, pre-arm check, mô phỏng vật lý drone.

Nghĩa là: **giao thức, timing, hành vi từ chối lệnh — tất cả đều thật.** Kỹ sư drone chuyên nghiệp dùng SITL để test hàng ngày. Dùng SITL không phải là "làm đồ chơi vì không có drone" — đó là quy trình chuẩn của ngành.

Nói được câu này khi phỏng vấn sẽ chuyển "em không có drone thật" từ điểm yếu thành hiểu biết về quy trình.
