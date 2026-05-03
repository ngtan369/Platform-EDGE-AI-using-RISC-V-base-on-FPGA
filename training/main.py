import os
import json
import argparse
import numpy as np
import tensorflow as tf
from tensorflow.keras import layers, models, applications

# ==========================================
# 1. DATASET PROCESSING
# ==========================================
def load_dataset(dataset_name, batch_size, img_size):
    """
    Hàm phân luồng tải dữ liệu tùy thuộc vào lựa chọn của người dùng.
    """
    if dataset_name == 'inria':
        print(f"[*] Đang tải tập dữ liệu: INRIA Person (Bài toán Phát hiện người)")
        num_classes = 2 # Background / Person
    elif dataset_name == 'cats_dogs':
        print(f"[*] Đang tải tập dữ liệu: Dogs vs. Cats (Bài toán Phân loại Chó/Mèo)")
        num_classes = 2 # Cat / Dog
    else:
        raise ValueError("Tập dữ liệu không được hỗ trợ!")

    print(f"    -> Kích thước ảnh đầu vào: {img_size}")
    
    # TODO: Khởi tạo tf.data.Dataset thật tại đây
    # train_dataset = ...
    # val_dataset = ...
    
    return None, None, num_classes # Tạm trả về None cho mục đích demo bộ khung

def representative_data_gen():
    """
    Hàm tạo dữ liệu đại diện cho quá trình Lượng tử hóa INT8.
    """
    # MOCK: Lấy 100 ảnh mẫu ngẫu nhiên (Thực tế phải lấy từ tập Validation của Dataset)
    for _ in range(100):
        yield [np.random.rand(1, 224, 224, 3).astype(np.float32)]

# ==========================================
# 2. MODEL FACTORY (Hardware-Software Co-design Options)
# ==========================================
def build_model(model_name, num_classes, input_shape=(224, 224, 3)):
    """
    Khởi tạo kiến trúc mạng dựa trên lựa chọn của người dùng.
    """
    print(f"[*] Đang khởi tạo kiến trúc: {model_name.upper()}")
    
    if model_name in ['vgg11', 'vgg16']:
        base_model = applications.VGG16(weights=None, input_shape=input_shape, include_top=False)
    elif model_name == 'resnet18':
        base_model = applications.ResNet50V2(weights=None, input_shape=input_shape, include_top=False)
    elif model_name == 'efficientnet-lite':
        base_model = applications.EfficientNetB0(weights=None, input_shape=input_shape, include_top=False)
    elif model_name in ['tiny-yolo', 'yolo-fastest']:
        print("[!] Lưu ý: Dòng YOLO yêu cầu cấu hình thêm Detection Head (Bounding box).")
        base_model = applications.MobileNetV2(weights=None, input_shape=input_shape, include_top=False)
    else:
        raise ValueError(f"Không hỗ trợ kiến trúc: {model_name}")

    # Phần Head chung cho Classification (Sẽ chạy trên ARM/RISC-V tùy phân chia)
    x = layers.GlobalAveragePooling2D()(base_model.output)
    output = layers.Dense(num_classes, activation='softmax')(x)
    
    model = models.Model(inputs=base_model.input, outputs=output)
    return model

# ==========================================
# 3. INT8 QUANTIZATION & EXPORT
# ==========================================
def export_to_int8(keras_model, output_path, dataset_name, model_name, fpga_input_size=(128, 128)):
    """
    Quy trình PTQ: Lượng tử hóa mô hình xuống INT8 cho BRAM.

    Xuất 2 file cạnh nhau:
      <output_path>          : .bin TFLite INT8 model (weights + ops)
      <output_path>.meta.json : input/output scale + zero_point + label map
                                ARM đọc file này lúc runtime để quantize ảnh.
    """
    print("[*] Bắt đầu quá trình Lượng tử hóa Post-Training (PTQ) INT8...")

    converter = tf.lite.TFLiteConverter.from_keras_model(keras_model)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    converter.representative_dataset = representative_data_gen

    # Ép IO xuống INT8 để giao tiếp qua AXI không cần khối chuyển đổi Float
    converter.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS_INT8]
    converter.inference_input_type = tf.int8
    converter.inference_output_type = tf.int8

    tflite_quant_model = converter.convert()

    with open(output_path, 'wb') as f:
        f.write(tflite_quant_model)
    print(f"[+] DONE! File trọng số INT8 đã sẵn sàng tại: {output_path}")

    # Trích xuất input/output quant params để ARM dùng runtime
    interp = tf.lite.Interpreter(model_content=tflite_quant_model)
    interp.allocate_tensors()
    in_detail  = interp.get_input_details()[0]
    out_detail = interp.get_output_details()[0]

    in_scale,  in_zp  = in_detail['quantization']    # (scale: float, zp: int)
    out_scale, out_zp = out_detail['quantization']

    LABEL_MAPS = {
        'inria':     ['no_person', 'person'],
        'cats_dogs': ['cat', 'dog'],
    }
    DATASET_IDS = {'inria': 0, 'cats_dogs': 1}

    meta = {
        'model':      model_name,
        'dataset':    dataset_name,
        'dataset_id': DATASET_IDS[dataset_name],
        'labels':     LABEL_MAPS[dataset_name],
        'input': {
            'shape':      list(in_detail['shape']),
            'dtype':      str(np.dtype(in_detail['dtype'])),
            'scale':      float(in_scale),
            'zero_point': int(in_zp),
            'fpga_size':  list(fpga_input_size),  # ARM resize tới size này trước khi quant
        },
        'output': {
            'shape':      list(out_detail['shape']),
            'dtype':      str(np.dtype(out_detail['dtype'])),
            'scale':      float(out_scale),
            'zero_point': int(out_zp),
        },
    }

    meta_path = output_path + '.meta.json'
    with open(meta_path, 'w') as f:
        json.dump(meta, f, indent=2, ensure_ascii=False)
    print(f"[+] Quant metadata: {meta_path}")
    print(f"    input:  scale={in_scale:.6g}, zero_point={in_zp}")
    print(f"    output: scale={out_scale:.6g}, zero_point={out_zp}")

# ==========================================
# MAIN EXECUTION FLOW
# ==========================================
if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="Edge AI Training & Quantization Pipeline")
    parser.add_argument('--model', type=str, default='resnet18', 
                        choices=['vgg11', 'vgg16', 'resnet18', 'tiny-yolo', 'yolo-fastest', 'efficientnet-lite'],
                        help="Chọn kiến trúc mạng CNN")
    parser.add_argument('--dataset', type=str, default='inria', 
                        choices=['inria', 'cats_dogs'],
                        help="Chọn tập dữ liệu huấn luyện (INRIA Person hoặc Chó/Mèo)")
    parser.add_argument('--epochs', type=int, default=50, help="Số epoch huấn luyện")
    parser.add_argument('--export_dir', type=str, default='./export', help="Thư mục lưu model INT8")
    
    args = parser.parse_args()
    os.makedirs(args.export_dir, exist_ok=True)
    
    print("="*50)
    print("   QUY TRÌNH BIÊN DỊCH MODEL CHO FPGA KRIA KV260   ")
    print("="*50)
    
    # 1. Load Dataset
    train_data, val_data, num_classes = load_dataset(args.dataset, batch_size=32, img_size=(224, 224))
    
    # 2. Xây dựng và Huấn luyện (Training)
    model = build_model(args.model, num_classes)
    model.compile(optimizer='adam', loss='sparse_categorical_crossentropy', metrics=['accuracy'])
    
    print(f"[*] Đang thực thi quá trình huấn luyện giả lập ({args.epochs} Epochs)...")
    # model.fit(train_data, validation_data=val_data, epochs=args.epochs)
    
    # 3. Lượng tử hóa và Xuất file (Quy ước đặt tên: Model_Dataset_INT8.bin)
    export_filename = os.path.join(args.export_dir, f"{args.model}_{args.dataset}_int8.bin")
    export_to_int8(model, export_filename,
                   dataset_name=args.dataset,
                   model_name=args.model)
    
    print("\n[!!!] Pipeline hoàn tất. Bạn có thể copy file .bin vào thẻ nhớ cho SoC Zynq đọc!")