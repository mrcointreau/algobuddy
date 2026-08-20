import Foundation

/// SHA-512/256 (FIPS 180-4 §5.3.6.2).
///
/// CryptoKit ships SHA-256, SHA-384 and SHA-512 but *not* the 512/256 variant,
/// which Algorand uses for address checksums. Note that SHA-512/256 is not
/// SHA-512 truncated. It uses a distinct set of initial hash values, so
/// truncating `CryptoKit.SHA512` would silently produce wrong digests.
///
/// The round constants below are the first 64 bits of the fractional parts of
/// the cube roots of the first 80 primes, generated with exact integer
/// arithmetic rather than transcribed by hand.
public enum SHA512_256 {

    public static func hash(_ message: [UInt8]) -> [UInt8] {
        var h = iv

        // Padding: 0x80, zeros to 112 mod 128, then a 128-bit big-endian bit count.
        var block = message
        let bitCount = UInt64(message.count) &* 8
        block.append(0x80)
        while block.count % 128 != 112 { block.append(0) }
        block.append(contentsOf: [UInt8](repeating: 0, count: 8))  // high 64 bits of length
        for shift in stride(from: 56, through: 0, by: -8) {
            block.append(UInt8(truncatingIfNeeded: bitCount >> UInt64(shift)))
        }

        var w = [UInt64](repeating: 0, count: 80)
        var offset = 0
        while offset < block.count {
            for t in 0..<16 {
                let base = offset + t * 8
                var value: UInt64 = 0
                for byte in 0..<8 { value = (value << 8) | UInt64(block[base + byte]) }
                w[t] = value
            }
            for t in 16..<80 {
                let s0 = rotr(w[t - 15], 1) ^ rotr(w[t - 15], 8) ^ (w[t - 15] >> 7)
                let s1 = rotr(w[t - 2], 19) ^ rotr(w[t - 2], 61) ^ (w[t - 2] >> 6)
                w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
            }

            var (a, b, c, d) = (h[0], h[1], h[2], h[3])
            var (e, f, g, hh) = (h[4], h[5], h[6], h[7])

            for t in 0..<80 {
                let s1 = rotr(e, 14) ^ rotr(e, 18) ^ rotr(e, 41)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[t] &+ w[t]
                let s0 = rotr(a, 28) ^ rotr(a, 34) ^ rotr(a, 39)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj

                hh = g
                g = f
                f = e
                e = d &+ t1
                d = c
                c = b
                b = a
                a = t1 &+ t2
            }

            h[0] = h[0] &+ a
            h[1] = h[1] &+ b
            h[2] = h[2] &+ c
            h[3] = h[3] &+ d
            h[4] = h[4] &+ e
            h[5] = h[5] &+ f
            h[6] = h[6] &+ g
            h[7] = h[7] &+ hh
            offset += 128
        }

        // Truncate to the leftmost 256 bits.
        var digest = [UInt8]()
        digest.reserveCapacity(32)
        for word in h[0..<4] {
            for shift in stride(from: 56, through: 0, by: -8) {
                digest.append(UInt8(truncatingIfNeeded: word >> UInt64(shift)))
            }
        }
        return digest
    }

    public static func hash(_ data: Data) -> Data {
        Data(hash([UInt8](data)))
    }

    private static func rotr(_ x: UInt64, _ n: UInt64) -> UInt64 {
        (x >> n) | (x << (64 - n))
    }

    /// SHA-512/256 initial hash values (FIPS 180-4 §5.3.6.2).
    private static let iv: [UInt64] = [
        0x2231_2194_FC2B_F72C, 0x9F55_5FA3_C84C_64C2,
        0x2393_B86B_6F53_B151, 0x9638_7719_5940_EABD,
        0x9628_3EE2_A88E_FFE3, 0xBE5E_1E25_5386_3992,
        0x2B01_99FC_2C85_B8AA, 0x0EB7_2DDC_81C5_2CA2,
    ]

    private static let k: [UInt64] = [
        0x428a_2f98_d728_ae22, 0x7137_4491_23ef_65cd, 0xb5c0_fbcf_ec4d_3b2f, 0xe9b5_dba5_8189_dbbc,
        0x3956_c25b_f348_b538, 0x59f1_11f1_b605_d019, 0x923f_82a4_af19_4f9b, 0xab1c_5ed5_da6d_8118,
        0xd807_aa98_a303_0242, 0x1283_5b01_4570_6fbe, 0x2431_85be_4ee4_b28c, 0x550c_7dc3_d5ff_b4e2,
        0x72be_5d74_f27b_896f, 0x80de_b1fe_3b16_96b1, 0x9bdc_06a7_25c7_1235, 0xc19b_f174_cf69_2694,
        0xe49b_69c1_9ef1_4ad2, 0xefbe_4786_384f_25e3, 0x0fc1_9dc6_8b8c_d5b5, 0x240c_a1cc_77ac_9c65,
        0x2de9_2c6f_592b_0275, 0x4a74_84aa_6ea6_e483, 0x5cb0_a9dc_bd41_fbd4, 0x76f9_88da_8311_53b5,
        0x983e_5152_ee66_dfab, 0xa831_c66d_2db4_3210, 0xb003_27c8_98fb_213f, 0xbf59_7fc7_beef_0ee4,
        0xc6e0_0bf3_3da8_8fc2, 0xd5a7_9147_930a_a725, 0x06ca_6351_e003_826f, 0x1429_2967_0a0e_6e70,
        0x27b7_0a85_46d2_2ffc, 0x2e1b_2138_5c26_c926, 0x4d2c_6dfc_5ac4_2aed, 0x5338_0d13_9d95_b3df,
        0x650a_7354_8baf_63de, 0x766a_0abb_3c77_b2a8, 0x81c2_c92e_47ed_aee6, 0x9272_2c85_1482_353b,
        0xa2bf_e8a1_4cf1_0364, 0xa81a_664b_bc42_3001, 0xc24b_8b70_d0f8_9791, 0xc76c_51a3_0654_be30,
        0xd192_e819_d6ef_5218, 0xd699_0624_5565_a910, 0xf40e_3585_5771_202a, 0x106a_a070_32bb_d1b8,
        0x19a4_c116_b8d2_d0c8, 0x1e37_6c08_5141_ab53, 0x2748_774c_df8e_eb99, 0x34b0_bcb5_e19b_48a8,
        0x391c_0cb3_c5c9_5a63, 0x4ed8_aa4a_e341_8acb, 0x5b9c_ca4f_7763_e373, 0x682e_6ff3_d6b2_b8a3,
        0x748f_82ee_5def_b2fc, 0x78a5_636f_4317_2f60, 0x84c8_7814_a1f0_ab72, 0x8cc7_0208_1a64_39ec,
        0x90be_fffa_2363_1e28, 0xa450_6ceb_de82_bde9, 0xbef9_a3f7_b2c6_7915, 0xc671_78f2_e372_532b,
        0xca27_3ece_ea26_619c, 0xd186_b8c7_21c0_c207, 0xeada_7dd6_cde0_eb1e, 0xf57d_4f7f_ee6e_d178,
        0x06f0_67aa_7217_6fba, 0x0a63_7dc5_a2c8_98a6, 0x113f_9804_bef9_0dae, 0x1b71_0b35_131c_471b,
        0x28db_77f5_2304_7d84, 0x32ca_ab7b_40c7_2493, 0x3c9e_be0a_15c9_bebc, 0x431d_67c4_9c10_0d4c,
        0x4cc5_d4be_cb3e_42b6, 0x597f_299c_fc65_7e2a, 0x5fcb_6fab_3ad6_faec, 0x6c44_198c_4a47_5817,
    ]
}
