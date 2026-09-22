//! A polar sweep grid: `[azimuth_bin][gate]` float32, row-major, with the sentinels of
//! `level2` (`< -900` is not data).

pub const VALID_ABOVE: f32 = -900.0;

#[derive(Clone, Debug, PartialEq)]
pub struct Grid {
    pub n_az: usize,
    pub n_gates: usize,
    pub data: Vec<f32>,
}

impl Grid {
    pub fn filled(n_az: usize, n_gates: usize, value: f32) -> Grid {
        Grid { n_az, n_gates, data: vec![value; n_az * n_gates] }
    }

    pub fn from_vec(n_az: usize, n_gates: usize, data: Vec<f32>) -> Grid {
        assert_eq!(data.len(), n_az * n_gates);
        Grid { n_az, n_gates, data }
    }

    #[inline]
    pub fn at(&self, az: usize, gate: usize) -> f32 {
        self.data[az * self.n_gates + gate]
    }

    #[inline]
    pub fn set(&mut self, az: usize, gate: usize, v: f32) {
        self.data[az * self.n_gates + gate] = v;
    }

    pub fn row(&self, az: usize) -> &[f32] {
        &self.data[az * self.n_gates..(az + 1) * self.n_gates]
    }

    pub fn row_mut(&mut self, az: usize) -> &mut [f32] {
        &mut self.data[az * self.n_gates..(az + 1) * self.n_gates]
    }

    pub fn len(&self) -> usize {
        self.data.len()
    }

    pub fn is_empty(&self) -> bool {
        self.data.is_empty()
    }

    /// Little-endian float16 bytes, the `.bin` file layout.
    pub fn to_f16_le(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(self.data.len() * 2);
        for &v in &self.data {
            out.extend_from_slice(&half::f16::from_f32(v).to_le_bytes());
        }
        out
    }

    pub fn from_f16_le(n_az: usize, n_gates: usize, bytes: &[u8]) -> Option<Grid> {
        if bytes.len() != n_az * n_gates * 2 {
            return None;
        }
        let data = bytes.as_chunks::<2>().0.iter().map(|b| half::f16::from_le_bytes(*b).to_f32()).collect();
        Some(Grid { n_az, n_gates, data })
    }
}
