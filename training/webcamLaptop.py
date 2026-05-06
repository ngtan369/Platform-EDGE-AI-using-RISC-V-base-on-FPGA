import cv2
import numpy as np
import tensorflow as tf

# 1. Load mô hình TFLite (INT8)
model_path = "mobilenet_v2_128_quant.tflite"
interpreter = tf.lite.Interpreter(model_path=model_path)
interpreter.allocate_tensors()

# Lấy thông tin đầu vào/đầu ra và các thông số lượng tử hóa (Scale, Zero Point)
input_details = interpreter.get_input_details()[0]
output_details = interpreter.get_output_details()[0]

in_scale, in_zero_point = input_details['quantization']
out_scale, out_zero_point = output_details['quantization']

# 2. Mở Webcam Laptop (Số 0 thường là camera mặc định)
cap = cv2.VideoCapture(0)

print("Đã mở Webcam. Nhấn phím 'q' để thoát.")

while True:
    ret, frame = cap.read()
    if not ret:
        break

    # 3. Tiền xử lý ảnh (Pre-processing) giống hệt lúc Train
    # Bóp về 128x128 và chuyển hệ màu từ BGR (OpenCV) sang RGB
    img_resized = cv2.resize(frame, (128, 128))
    img_rgb = cv2.cvtColor(img_resized, cv2.COLOR_BGR2RGB)

    # 4. Ép kiểu dữ liệu ảnh vào chuẩn INT8 của TFLite
    input_data = np.float32(img_rgb)
    if in_scale != 0:
        # Công thức Quantize: (Giá trị thực / Scale) + Zero_Point
        input_data = (input_data / in_scale) + in_zero_point
    
    # Ép thành kiểu int8 và thêm chiều batch (1, 128, 128, 3)
    input_data = np.expand_dims(input_data.astype(np.int8), axis=0)

    # 5. Suy luận (Inference)
    interpreter.set_tensor(input_details['index'], input_data)
    interpreter.invoke()

    # 6. Hậu xử lý kết quả (Post-processing)
    output_data = interpreter.get_tensor(output_details['index'])[0][0]
    
    # Dịch ngược từ INT8 ra số thực (Xác suất từ 0.0 đến 1.0)
    probability = (output_data - out_zero_point) * out_scale

    # 7. Hiển thị lên màn hình
    if probability > 0.5:
        text = f"Co nguoi! ({probability*100:.1f}%)"
        color = (0, 255, 0) # Màu Xanh lá
    else:
        text = f"Khong co nguoi ({probability*100:.1f}%)"
        color = (0, 0, 255) # Màu Đỏ

    # Vẽ chữ lên khung hình gốc của Webcam
    cv2.putText(frame, text, (20, 50), cv2.FONT_HERSHEY_SIMPLEX, 1, color, 2)
    cv2.imshow('Camera Test - Edge AI', frame)

    # Nhấn 'q' để thoát
    if cv2.waitKey(1) & 0xFF == ord('q'):
        break

cap.release()
cv2.destroyAllWindows()