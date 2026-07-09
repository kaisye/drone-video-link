# 05 — Các quyết định kỹ thuật

> Mỗi quyết định ghi theo dạng: **bối cảnh → lựa chọn → đánh đổi**. Khi phỏng vấn, người ta không hỏi "em dùng gì" mà hỏi "vì sao em dùng cái đó". File này là câu trả lời.

---

## D1. Không làm Yocto/Buildroot trong 2 ngày

**Bối cảnh:** JD liệt kê Yocto, Buildroot, U-Boot, Device Tree.

**Chọn:** bỏ hoàn toàn.

**Vì sao:** build Yocto lần đầu tốn 4–8 tiếng và ~50GB disk. Sản phẩm demo được là một dòng `login:` trên console. Tỉ lệ *giá trị / thời gian* tệ nhất trong mọi lựa chọn.

**Đánh đổi:** mất một gạch đầu dòng trong phần "Yêu cầu". Chấp nhận được, vì phần "Trách nhiệm chính" của JD — thứ mô tả công việc hằng ngày — là GStreamer/MAVLink, không phải Yocto.

**Nói gì khi phỏng vấn:** *"Em chưa build Yocto image thật vì trong 2 ngày em ưu tiên phần lõi của JD. Em hiểu Yocto là build system tạo distro Linux tuỳ biến qua layer và recipe, và BSP của Jetson dùng nó. Em sẵn sàng học."* — Thành thật, cụ thể, có định hướng. Tốt hơn nhiều so với một image nửa vời.

---

## D2. Receiver viết bằng C++, không phải Python hay shell

**Bối cảnh:** chạy `gst-launch-1.0` là đủ để video hiện lên màn hình.

**Chọn:** viết `receiver.cpp` dùng GStreamer C API + `appsink`, build bằng CMake.

**Vì sao:** JD ghi rõ *"Thành thạo lập trình với C, C++"* và *"Sử dụng CMake để xây dựng dự án"*. Một project chỉ có shell script chạy `gst-launch` **không chứng minh được điều gì về khả năng lập trình**. Câu hỏi đầu tiên của người phỏng vấn sẽ là: *"em dùng gst-launch hay tự viết app?"*

Đây là **quyết định quan trọng nhất trong toàn bộ project**. Nếu chỉ đủ thời gian làm một thứ, làm cái này.

**Đánh đổi:** tốn 3 tiếng thay vì 20 phút. Xứng đáng.

---

## D3. Python cho MAVLink gateway

**Bối cảnh:** có thể viết bằng C++ với MAVSDK-C++.

**Chọn:** Python + `pymavlink`.

**Vì sao:** JD ghi *"Python (test tool, scripting)"* — đúng vai trò của một gateway/tool. Ngoài đời, MAVLink gateway và ground-station tooling **thường là Python thật**. Dùng C++ ở đây không thể hiện thêm điều gì mà C++ ở receiver chưa thể hiện, lại tốn gấp ba thời gian.

Việc phân vai C++ cho data-plane (video, hiệu năng) và Python cho control-plane (lệnh, log) chính là kiến trúc mà các hệ thống thật dùng. Nói được điều đó là một điểm cộng.

---

## D4. Một repo, hai thành phần, không tích hợp code

**Chọn:** `drone-video-link/` chứa `video/` + `mavlink/`, chung một README và một sơ đồ. Hai thành phần không gọi nhau.

**Vì sao:** nhà tuyển dụng lướt CV ~15 giây. "Ground-station link cho drone" đọc như **một hệ thống**; hai repo rời đọc như **hai bài tutorial**. Vẫn viết được hai bullet CV từ một repo.

**Đánh đổi:** phải cưỡng lại ý muốn ép chúng tích hợp với nhau. Tích hợp thật tốn cả ngày và **không thêm kiến thức mới nào** — chỉ thêm code keo dán.

---

## D5. Đo latency, không đo FPS

**Bối cảnh:** gợi ý ban đầu là "hiển thị FPS".

**Chọn:** đo latency bằng `GST_TRACERS=latency`, lập bảng so sánh default vs tuned.

**Vì sao:** JD nói *"độ trễ thấp"*. **FPS không phải latency.** Hoàn toàn có thể đạt 30 FPS ổn định với 2 giây độ trễ — buffer sâu cho FPS đẹp và latency thảm hoạ. Đo nhầm chỉ số là hiểu nhầm bài toán, và người phỏng vấn sẽ nhận ra ngay.

Bảng latency **kèm giải thích vì sao mỗi con số giảm** là deliverable giá trị nhất của cả project.

---

## D6. Bỏ script monitor CPU/RAM, dùng công cụ thật

**Bối cảnh:** gợi ý ban đầu có "script monitor CPU/RAM".

**Chọn:** `GST_TRACERS`, `GST_DEBUG`, và `valgrind --leak-check=full` trên `receiver`.

**Vì sao:** `top` chạy trong vòng lặp không chứng minh được gì. JD ghi *"debug các vấn đề về bộ nhớ, hiệu suất"* — nghĩa là những công cụ trên. Chúng cho ra **số liệu quy trách nhiệm được đến từng element**, và chúng là thứ kỹ sư GStreamer thật sự gõ hằng ngày.

Chuỗi `ref`/`unref` của GStreamer là nguồn memory leak kinh điển. Chạy valgrind một lần và lưu output vào `results/` là bằng chứng cụ thể.

---

## D7. Thêm thí nghiệm `tc netem`

**Chọn:** chèn 2% packet loss + 20ms jitter, chụp ảnh vỡ hình, giải thích qua GOP.

**Vì sao:** không có nó, "low-latency video over Ethernet" chỉ là chữ trên CV. Có nó, bạn chứng minh được mình hiểu **vì sao UDP được chọn**, **vì sao RTP tồn tại**, và **vì sao `key-int-max` quan trọng**. Ba khái niệm, một thí nghiệm một tiếng.

Đây là thứ tách ứng viên hiểu bài khỏi ứng viên copy pipeline từ StackOverflow.

---

## D8. Bỏ project Wokwi FreeRTOS ESP32

**Bối cảnh:** gợi ý ban đầu đề xuất nó làm project phụ để phủ "Kiến thức về RTOS".

**Chọn:** bỏ.

**Vì sao:** CV đã có STM32, CAN, IMU, EKF, PID — **phần cứng thật**. Thêm một project ESP32 mô phỏng mức nhập môn (task + queue + OLED) sẽ **làm loãng** phần embedded vốn đang mạnh, không làm nó mạnh thêm. Ngoài ra RTOS nằm ở mục "Kiến thức về", **không xuất hiện trong bất kỳ trách nhiệm chính nào**.

**Thay bằng:** Dockerfile (phủ "containerization cho build và deploy") + MQTT bridge (phủ "tích hợp với Cloud: MQTT"). Khoảng 2 tiếng, phủ **hai** gạch đầu dòng thay vì một.

**Nếu CV thật sự không có dòng RTOS nào:** kiểm tra lại dự án STM32 cũ — nếu nó dùng FreeRTOS thì chỉ cần ghi rõ ra là xong, không cần làm project mới.

---

## D9. `videotestsrc` thay vì camera thật

**Vì sao:** camera thật không dạy thêm điều gì mà pipeline giả lập chưa dạy. Đổi sang camera thật là **sửa đúng một element** (`videotestsrc` → `v4l2src`). Mọi kiến thức về encode, RTP, jitter buffer, latency đều giữ nguyên.

Ngược lại, `videotestsrc` cho ta thứ camera không cho: **nội dung lặp lại được**, nên phép đo latency so sánh được giữa các lần chạy.

---

## D10. Cả hai đầu chạy trong cùng một distro WSL

**Vì sao:** WSL2 nằm sau NAT. Gửi UDP từ WSL sang Windows cần bật `networkingMode=mirrored`, và debug chuyện đó là thời gian đổ xuống sông — nó không dạy gì về video streaming.

Loopback `127.0.0.1` cũng cho một lợi ích thật: `tc netem` trên `lo` cho ta **toàn quyền kiểm soát điều kiện mạng**, thứ mà mạng thật không bao giờ cho.

**Đánh đổi:** không đo được latency của NIC thật. Không quan trọng — latency của pipeline (encode + buffer + decode) lớn hơn latency LAN cả bậc độ lớn.
