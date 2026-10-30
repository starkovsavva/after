use std::{
    collections::VecDeque,
    fs::{File, OpenOptions},
    io::{self, Seek, SeekFrom, Write},
    path::Path,
};
pub const RATE: u64 = 48_000;
const MAX_PENDING: u64 = RATE * 4;

/// A recoverable PCM file: every checkpoint fixes its RIFF lengths and syncs it.
pub struct Wav {
    file: File,
    frames: u64,
    checkpoint: u64,
}
impl Wav {
    pub fn create(path: &Path) -> io::Result<Self> {
        let mut options = OpenOptions::new();
        options.write(true).read(true).create_new(true);
        // Keep the name pinned while recording; a concurrent replacement cannot
        // redirect the source imported after finalization.
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            options.share_mode(3);
        }
        let file = options.open(path)?;
        let mut w = Self {
            file,
            frames: 0,
            checkpoint: 0,
        };
        w.header()?;
        Ok(w)
    }
    fn header(&mut self) -> io::Result<()> {
        let size = u32::try_from(self.frames * 2)
            .map_err(|_| io::Error::other("WAV recording exceeds the supported size"))?;
        if size > u32::MAX - 36 {
            return Err(io::Error::other("WAV recording exceeds the supported size"));
        }
        let mut h = Vec::with_capacity(44);
        h.extend_from_slice(b"RIFF");
        h.extend_from_slice(&(36 + size).to_le_bytes());
        h.extend_from_slice(b"WAVEfmt ");
        h.extend_from_slice(&16u32.to_le_bytes());
        h.extend_from_slice(&1u16.to_le_bytes());
        h.extend_from_slice(&1u16.to_le_bytes());
        h.extend_from_slice(&(RATE as u32).to_le_bytes());
        h.extend_from_slice(&((RATE * 2) as u32).to_le_bytes());
        h.extend_from_slice(&2u16.to_le_bytes());
        h.extend_from_slice(&16u16.to_le_bytes());
        h.extend_from_slice(b"data");
        h.extend_from_slice(&size.to_le_bytes());
        self.file.seek(SeekFrom::Start(0))?;
        self.file.write_all(&h)?;
        self.file.seek(SeekFrom::End(0))?;
        self.file.sync_data()?;
        self.checkpoint = self.frames;
        Ok(())
    }
    pub fn write(&mut self, samples: &[f32]) -> io::Result<()> {
        if self.frames + samples.len() as u64 > (u32::MAX as u64 - 36) / 2 {
            return Err(io::Error::other("WAV recording exceeds the supported size"));
        }
        let mut bytes = Vec::with_capacity(samples.len() * 2);
        for &sample in samples {
            let value = if sample.is_finite() {
                sample.clamp(-1.0, 1.0)
            } else {
                0.0
            };
            bytes.extend_from_slice(&((value * 32767.0) as i16).to_le_bytes());
        }
        self.file.write_all(&bytes)?;
        self.frames += samples.len() as u64;
        if self.frames - self.checkpoint >= RATE {
            self.header()?;
        }
        Ok(())
    }
    pub fn finish(&mut self) -> io::Result<()> {
        self.header()
    }
}

/// Align both streams against the shared WASAPI QPC clock before mixing them.
pub struct Mixer {
    pending: VecDeque<[f32; 2]>,
    written: u64,
}
impl Mixer {
    pub fn new() -> Self {
        Self {
            pending: VecDeque::new(),
            written: 0,
        }
    }
    pub fn push(&mut self, source: usize, offset: u64, samples: &[f32]) -> io::Result<()> {
        if source > 1 {
            return Err(io::Error::other("Invalid audio source"));
        }
        let end = offset
            .checked_add(samples.len() as u64)
            .ok_or_else(|| io::Error::other("Invalid audio timestamp"))?;
        if end <= self.written {
            return Err(io::Error::other("Audio arrived too late to synchronize"));
        }
        if end.saturating_sub(self.written) > MAX_PENDING {
            return Err(io::Error::other(
                "Audio timestamp is outside the synchronization window",
            ));
        }
        let skip = self.written.saturating_sub(offset) as usize;
        if skip > 0 {
            return Err(io::Error::other("Audio arrived too late to synchronize"));
        }
        let needed = end.saturating_sub(self.written) as usize;
        self.pending
            .resize(needed.max(self.pending.len()), [0.0, 0.0]);
        for (i, value) in samples.iter().enumerate() {
            self.pending[(offset - self.written) as usize + i][source] = *value;
        }
        Ok(())
    }
    pub fn flush(&mut self, until: u64, wav: &mut Wav) -> io::Result<()> {
        let count = until.saturating_sub(self.written);
        if count > MAX_PENDING {
            return Err(io::Error::other("Audio capture fell behind"));
        }
        let mut data = Vec::with_capacity(count as usize);
        for _ in 0..count {
            let value = self.pending.pop_front().unwrap_or([0.0, 0.0]);
            data.push(value[0] + value[1]);
        }
        wav.write(&data)?;
        self.written += count;
        Ok(())
    }
    pub fn finish(&mut self, until: u64, wav: &mut Wav) -> io::Result<()> {
        self.flush(until.max(self.written + self.pending.len() as u64), wav)?;
        wav.finish()
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn aligns_mixes_and_persists_playable_wav() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("source.wav");
        let mut w = Wav::create(&path).unwrap();
        let mut m = Mixer::new();
        m.push(0, 1, &[0.25, 0.5]).unwrap();
        m.push(1, 2, &[0.25]).unwrap();
        m.finish(4, &mut w).unwrap();
        let b = std::fs::read(path).unwrap();
        assert_eq!(&b[..4], b"RIFF");
        assert_eq!(u32::from_le_bytes(b[40..44].try_into().unwrap()), 8);
        let pcm: Vec<i16> = b[44..]
            .chunks_exact(2)
            .map(|v| i16::from_le_bytes(v.try_into().unwrap()))
            .collect();
        assert_eq!(pcm, vec![0, 8191, 24575, 0]);
    }
    #[test]
    fn rejects_late_and_unbounded_timestamps() {
        let dir = tempfile::tempdir().unwrap();
        let mut w = Wav::create(&dir.path().join("x.wav")).unwrap();
        let mut m = Mixer::new();
        m.flush(10, &mut w).unwrap();
        assert!(m.push(0, 9, &[0.2, 0.3]).is_err());
        assert!(m.push(0, RATE * 10, &[0.2]).is_err());
    }
    #[test]
    fn checkpoint_is_readable_before_finish() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("x.wav");
        let mut w = Wav::create(&path).unwrap();
        w.write(&vec![0.0; RATE as usize]).unwrap();
        let b = std::fs::read(path).unwrap();
        assert_eq!(
            u32::from_le_bytes(b[40..44].try_into().unwrap()),
            RATE as u32 * 2
        );
    }
}

/// Repair a checkpoint after a process crash. The file handle and its parents
/// are kept pinned by the caller. Never accept arbitrary formats or >4 GiB.
pub fn repair(file: &mut File) -> io::Result<()> {
    use std::io::Read;
    let length = file.metadata()?.len();
    if length < 46 || length > (u32::MAX as u64 + 8) {
        return Err(io::Error::other("Invalid WAV size"));
    }
    let mut header = [0u8; 44];
    file.seek(SeekFrom::Start(0))?;
    file.read_exact(&mut header)?;
    if &header[0..4] != b"RIFF"
        || &header[8..16] != b"WAVEfmt "
        || &header[36..40] != b"data"
        || u16::from_le_bytes(header[20..22].try_into().unwrap()) != 1
        || u16::from_le_bytes(header[22..24].try_into().unwrap()) != 1
        || u32::from_le_bytes(header[24..28].try_into().unwrap()) != RATE as u32
        || u16::from_le_bytes(header[34..36].try_into().unwrap()) != 16
    {
        return Err(io::Error::other("Unsupported WAV recording"));
    }
    let data = ((length - 44) / 2 * 2) as u32;
    file.set_len(data as u64 + 44)?;
    file.seek(SeekFrom::Start(4))?;
    file.write_all(&(36 + data).to_le_bytes())?;
    file.seek(SeekFrom::Start(40))?;
    file.write_all(&data.to_le_bytes())?;
    file.sync_all()
}
