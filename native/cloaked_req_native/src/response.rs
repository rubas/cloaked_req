use rustler::NifMap;

#[derive(Debug, NifMap)]
#[rustler(encode)]
pub struct NativeResponseMeta {
    pub status: u16,
    pub url: String,
    pub headers: Vec<(String, String)>,
}
