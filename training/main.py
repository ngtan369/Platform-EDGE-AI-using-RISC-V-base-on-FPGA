import os
import xml.etree.ElementTree as ET
import tensorflow as tf
import numpy as np
import kagglehub

# ==========================================
# 1. PARSE DỮ LIỆU TỪ FILE XML (PASCAL VOC)
# ==========================================
print("Đang chuẩn bị dữ liệu tọa độ...")
# Giả sử bạn đã có đường dẫn dataset từ Kaggle
dataset_path = kagglehub.dataset_download("jcoral02/inriaperson")
img_dir = os.path.join(dataset_path, "Train", "JPEGImages")
xml_dir = os.path.join(dataset_path, "Train", "Annotations")

image_paths = []
bounding_boxes = []

# Quét toàn bộ file XML
for xml_file in os.listdir(xml_dir):
    if not xml_file.endswith('.xml'): continue
    
    tree = ET.parse(os.path.join(xml_dir, xml_file))
    root = tree.getroot()
    
    # Lấy tên file ảnh
    filename = root.find('filename').text
    img_path = os.path.join(img_dir, filename)
    
    # Bỏ qua nếu ảnh không tồn tại
    if not os.path.exists(img_path): continue
        
    # Lấy kích thước ảnh gốc
    size = root.find('size')
    width = float(size.find('width').text)
    height = float(size.find('height').text)
    
    # Lấy tọa độ Box (Giả định lấy người đầu tiên trong ảnh)
    bndbox = root.find('object').find('bndbox')
    xmin = float(bndbox.find('xmin').text)
    ymin = float(bndbox.find('ymin').text)
    xmax = float(bndbox.find('xmax').text)
    ymax = float(bndbox.find('ymax').text)
    
    # CHUẨN HÓA: Đưa tọa độ về dải [0.0 -> 1.0] để AI dễ học
    norm_box = [
        xmin / width, 
        ymin / height, 
        xmax / width, 
        ymax / height
    ]
    
    image_paths.append(img_path)
    bounding_boxes.append(norm_box)

print(f"Đã tìm thấy {len(image_paths)} ảnh có chứa tọa độ Box hợp lệ.")

# ==========================================
# 2. XÂY DỰNG TENSORFLOW DATASET TỐC ĐỘ CAO
# ==========================================
IMG_SIZE = (128, 128)
BATCH_SIZE = 32

def process_path(img_path, bbox):
    # Đọc và resize ảnh
    img = tf.io.read_file(img_path)
    img = tf.image.decode_jpeg(img, channels=3)
    img = tf.image.resize(img, IMG_SIZE)
    return img, bbox

# Tạo Dataset từ mảng list
dataset = tf.data.Dataset.from_tensor_slices((image_paths, bounding_boxes))
dataset = dataset.map(process_path, num_parallel_calls=tf.data.AUTOTUNE)

# Chia Train/Val (80/20)
data_size = len(image_paths)
train_size = int(0.8 * data_size)

dataset = dataset.shuffle(1000)
train_dataset = dataset.take(train_size).batch(BATCH_SIZE).prefetch(tf.data.AUTOTUNE)
val_dataset = dataset.skip(train_size).batch(BATCH_SIZE).prefetch(tf.data.AUTOTUNE)

# ==========================================
# 3. MÔ HÌNH NHẢ RA TỌA ĐỘ (REGRESSION HEAD)
# ==========================================
print("Đang xây dựng mô hình Regression...")
base_model = tf.keras.applications.MobileNetV2(
    input_shape=(128, 128, 3),
    alpha=0.5,
    include_top=False,
    weights='imagenet'
)
base_model.trainable = False # Đóng băng

model = tf.keras.Sequential([
    tf.keras.layers.Rescaling(1./127.5, offset=-1),
    base_model,
    tf.keras.layers.GlobalAveragePooling2D(),
    
    # KHÁC BIỆT Ở ĐÂY: Dense(4) thay vì Dense(1)
    # Dùng 'sigmoid' vì ngõ ra (tọa độ chuẩn hóa) nằm trong khoảng [0, 1]
    tf.keras.layers.Dense(128, activation='relu'),
    tf.keras.layers.Dense(4, activation='sigmoid', name='bounding_box_output')
])

# Hàm Loss là MSE (Đo khoảng cách lệch giữa Box đoán và Box thực)
model.compile(
    optimizer=tf.keras.optimizers.Adam(learning_rate=0.001),
    loss='mean_squared_error',
    metrics=['mae'] # Mean Absolute Error
)

# ==========================================
# 4. TRAINING VÀ XUẤT FILE C
# ==========================================
print("Bắt đầu Training Box...")
model.fit(train_dataset, validation_data=val_dataset, epochs=15)


# ==========================================
# 4. ÉP KIỂU (QUANTIZATION) SANG INT8
# ==========================================
print("Bắt đầu lượng tử hóa xuống INT8...")

def representative_data_gen():
    for input_value, _ in train_dataset.take(50): 
        # Ép kiểu float32 để TFLite đọc chuẩn xác
        yield [tf.cast(input_value, tf.float32)] 

converter = tf.lite.TFLiteConverter.from_keras_model(model)
converter.optimizations = [tf.lite.Optimize.DEFAULT]
converter.representative_dataset = representative_data_gen

converter.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS_INT8]
converter.inference_input_type = tf.int8
converter.inference_output_type = tf.int8

tflite_model_quant = converter.convert()

tflite_path = 'mobilenet_v2_128_quant.tflite'
with open(tflite_path, 'wb') as f:
    f.write(tflite_model_quant)

# ==========================================
# 5. XUẤT RA MẢNG C CHO NHÚNG BARE-METAL
# ==========================================
print("Đang xuất mảng C-Header...")
with open(tflite_path, 'rb') as f:
    tflite_content = f.read()

hex_array = ', '.join([f'0x{byte:02x}' for byte in tflite_content])

c_code = f"""
#ifndef MODEL_DATA_H
#define MODEL_DATA_H

// Kích thước mảng: {len(tflite_content)} bytes
const unsigned int model_data_len = {len(tflite_content)};
const unsigned char model_data[] __attribute__((aligned(4))) = {{
    {hex_array}
}};

#endif // MODEL_DATA_H
"""

with open("model_data.h", 'w') as f:
    f.write(c_code)

print("HOÀN TẤT TOÀN BỘ QUY TRÌNH!")