//! AES-256-CTR 客户端文件加密，与 Cloudreve 前端 EncryptedBlob / 桌面客户端
//! cloudreve-sync 的实现保持字节级兼容。

use aes::Aes256;
use aes::cipher::{KeyIvInit, StreamCipher};
use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine as _;
use ctr::Ctr128BE;

use crate::errors::{Result, SyncError};
use crate::models::EncryptMetadata;

type Aes256Ctr = Ctr128BE<Aes256>;

/// 加密配置，由服务端下发的 `encrypt_metadata` 派生。
#[derive(Clone)]
pub struct EncryptionConfig {
    key: [u8; 32],
    iv: [u8; 16],
}

impl EncryptionConfig {
    /// 从 Cloudreve 的 encrypt_metadata 构造加密配置。
    pub fn from_metadata(metadata: &EncryptMetadata) -> Result<Self> {
        if !metadata.algorithm.is_empty()
            && metadata.algorithm.to_lowercase() != "aes-256-ctr"
        {
            return Err(SyncError::UploadFailed(format!(
                "不支持的客户端加密算法: {}",
                metadata.algorithm
            )));
        }

        let key_bytes = BASE64
            .decode(&metadata.key_plain_text)
            .map_err(|e| SyncError::UploadFailed(format!("加密密钥 base64 解码失败: {}", e)))?;
        let iv_bytes = BASE64
            .decode(&metadata.iv)
            .map_err(|e| SyncError::UploadFailed(format!("加密 IV base64 解码失败: {}", e)))?;

        if key_bytes.len() != 32 {
            return Err(SyncError::UploadFailed(format!(
                "加密密钥长度异常：期望 32 字节，实际 {} 字节",
                key_bytes.len()
            )));
        }
        if iv_bytes.len() != 16 {
            return Err(SyncError::UploadFailed(format!(
                "加密 IV 长度异常：期望 16 字节，实际 {} 字节",
                iv_bytes.len()
            )));
        }

        let mut key = [0u8; 32];
        let mut iv = [0u8; 16];
        key.copy_from_slice(&key_bytes);
        iv.copy_from_slice(&iv_bytes);

        Ok(Self { key, iv })
    }

    /// 创建计数器已按给定字节偏移调整的 cipher 实例。
    fn create_cipher_at_offset(&self, byte_offset: u64) -> Aes256Ctr {
        let block_offset = byte_offset / 16;
        let mut counter = self.iv;
        Self::increment_counter(&mut counter, block_offset);
        Aes256Ctr::new(&self.key.into(), &counter.into())
    }

    /// 128 位大端计数器递增，与 Cloudreve 前端 EncryptedBlob 一致。
    fn increment_counter(counter: &mut [u8; 16], blocks: u64) {
        let mut carry = blocks;
        for i in (0..16).rev() {
            if carry == 0 {
                break;
            }
            let sum = counter[i] as u64 + (carry & 0xFF);
            counter[i] = (sum & 0xFF) as u8;
            carry = (carry >> 8) + (sum >> 8);
        }
    }

    /// 加密一段数据，从文件内字节偏移 byte_offset 起。
    ///
    /// 分片边界无需与 AES 块边界对齐：偏移按字节计算，内部先跳过多余的
    /// 块内偏移，与 Go 端 `cipher.NewCTR` + 跳过 offsetInBlock 的语义一致。
    pub fn encrypt_at_offset(&self, data: &mut [u8], byte_offset: u64) {
        let mut cipher = self.create_cipher_at_offset(byte_offset);

        let offset_in_block = (byte_offset % 16) as usize;
        if offset_in_block != 0 {
            let first_block_remaining = (16 - offset_in_block).min(data.len());
            let mut temp_block = [0u8; 16];
            temp_block[offset_in_block..offset_in_block + first_block_remaining]
                .copy_from_slice(&data[..first_block_remaining]);
            cipher.apply_keystream(&mut temp_block);
            data[..first_block_remaining].copy_from_slice(
                &temp_block[offset_in_block..offset_in_block + first_block_remaining],
            );

            if data.len() > first_block_remaining {
                cipher.apply_keystream(&mut data[first_block_remaining..]);
            }
        } else {
            cipher.apply_keystream(data);
        }
    }
}
