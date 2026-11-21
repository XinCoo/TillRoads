// 纯 Dart 的 SHA-256（本地优先架构 R2）。
//
// 为什么自己写 60 行而不是 `flutter pub add crypto`：
//   · R2 任务书硬约束「不引新依赖」，而 `crypto` 目前既不是直接依赖也不是
//     可靠的单层传递依赖（传递依赖随时可能被上游删掉，直接 import 会触发
//     `depend_on_referenced_packages` lint，破坏「analyze 0 warning」）；
//   · 这里唯一的需求是「给 token 算一个稳定的短指纹」，不需要 HMAC / 流式 /
//     并行等 crypto 包的能力；
//   · 算法是公开的、可被 FIPS 180-4 的官方测试向量钉死的（见
//     `test/sha256_test.dart` 的三组长/短向量），自测比信任实现更划算。
//
// 用法只有一处：`token_fingerprint.dart` 里的 `tokenFingerprint()`。
// **不要**把它当通用加密工具——它没有做常量时间比较，也不适合校验签名。

import 'dart:convert';
import 'dart:typed_data';

/// SHA-256 的 32 字节摘要算法（FIPS 180-4）。
abstract final class Sha256 {
  /// 轮常量：前 64 个素数立方根小数部分的前 32 位。
  static const List<int> _k = <int>[
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  /// 初始哈希值：前 8 个素数平方根小数部分的前 32 位。
  static const List<int> _h0 = <int>[
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];

  static const int _mask = 0xffffffff;

  /// 对 UTF-8 编码后的 [input] 求摘要，返回 32 字节。
  static Uint8List digestBytes(String input) => digest(utf8.encode(input));

  /// 对任意字节序列求摘要，返回 32 字节。
  static Uint8List digest(List<int> input) {
    // ① 填充：0x80 + 若干 0x00，使总长 ≡ 56 (mod 64)，末尾 8 字节放比特长度（大端）。
    final int bitLength = input.length * 8;
    final int paddedLength = ((input.length + 9 + 63) ~/ 64) * 64;
    final Uint8List padded = Uint8List(paddedLength)..setRange(0, input.length, input);
    padded[input.length] = 0x80;
    // 比特长度用大端写入最后 8 字节。Dart 的 int 在 VM 上是 64 位有符号，
    // 这里先拆高低 32 位再各自写 4 字节，避免依赖 BigInt。
    final int high = bitLength ~/ 0x100000000;
    final int low = bitLength & _mask;
    final ByteData view = ByteData.view(padded.buffer);
    view.setUint32(paddedLength - 8, high, Endian.big);
    view.setUint32(paddedLength - 4, low, Endian.big);

    // ② 逐 64 字节分块处理。
    final Uint32List h = Uint32List.fromList(_h0);
    final Uint32List w = Uint32List(64);

    for (int chunk = 0; chunk < paddedLength; chunk += 64) {
      for (int i = 0; i < 16; i++) {
        w[i] = view.getUint32(chunk + i * 4, Endian.big);
      }
      for (int i = 16; i < 64; i++) {
        final int s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
        final int s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & _mask;
      }

      int a = h[0];
      int b = h[1];
      int c = h[2];
      int d = h[3];
      int e = h[4];
      int f = h[5];
      int g = h[6];
      int hh = h[7];

      for (int i = 0; i < 64; i++) {
        final int s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
        final int ch = (e & f) ^ ((~e & _mask) & g);
        final int temp1 = (hh + s1 + ch + _k[i] + w[i]) & _mask;
        final int s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
        final int maj = (a & b) ^ (a & c) ^ (b & c);
        final int temp2 = (s0 + maj) & _mask;

        hh = g;
        g = f;
        f = e;
        e = (d + temp1) & _mask;
        d = c;
        c = b;
        b = a;
        a = (temp1 + temp2) & _mask;
      }

      h[0] = (h[0] + a) & _mask;
      h[1] = (h[1] + b) & _mask;
      h[2] = (h[2] + c) & _mask;
      h[3] = (h[3] + d) & _mask;
      h[4] = (h[4] + e) & _mask;
      h[5] = (h[5] + f) & _mask;
      h[6] = (h[6] + g) & _mask;
      h[7] = (h[7] + hh) & _mask;
    }

    // ③ 输出 32 字节大端。
    final Uint8List out = Uint8List(32);
    final ByteData outView = ByteData.view(out.buffer);
    for (int i = 0; i < 8; i++) {
      outView.setUint32(i * 4, h[i], Endian.big);
    }
    return out;
  }

  /// 对 [input] 求摘要，返回 64 位小写十六进制字符串。
  static String hex(String input) => _toHex(digestBytes(input));

  /// 对任意字节求摘要的十六进制形式。
  static String hexOfBytes(List<int> input) => _toHex(digest(input));

  static String _toHex(Uint8List bytes) {
    final StringBuffer sb = StringBuffer();
    for (final int b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// 32 位无符号右旋。
  static int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & _mask;
}
