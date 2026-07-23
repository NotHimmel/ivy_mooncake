use pgrx::pg_sys;
use std::ffi::CStr;
use std::future::Future;
use std::sync::{LazyLock, Mutex, MutexGuard};
use tokio::net::UnixStream;
use tokio::runtime::{Builder, Runtime};

pub(crate) static DATABASE: LazyLock<String> = LazyLock::new(|| {
    let database = unsafe { CStr::from_ptr(pg_sys::get_database_name(pg_sys::MyDatabaseId)) };
    database.to_str().unwrap().to_owned()
});

pub(crate) fn block_on<F: Future>(future: F) -> F::Output {
    static RUNTIME: LazyLock<Runtime> = LazyLock::new(|| {
        Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("Failed to create tokio runtime")
    });
    RUNTIME.block_on(future)
}

pub(crate) fn get_stream() -> MutexGuard<'static, UnixStream> {
    static STREAM: LazyLock<Mutex<UnixStream>> = LazyLock::new(|| {
        // The moonlink bgworker binds its socket asynchronously after postmaster
        // start, so the first client call in a fresh cluster can race it and see
        // ECONNREFUSED/ENOENT. Retry with backoff instead of failing the backend:
        // a panic here would also poison this LazyLock, permanently breaking every
        // later mooncake call in the session.
        let mut delay = std::time::Duration::from_millis(50);
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        let stream = loop {
            match block_on(UnixStream::connect("pg_mooncake/moonlink.sock")) {
                Ok(stream) => break stream,
                Err(err) if std::time::Instant::now() < deadline => {
                    pgrx::log!("moonlink not ready ({err}), retrying in {delay:?}");
                    std::thread::sleep(delay);
                    delay = (delay * 2).min(std::time::Duration::from_secs(1));
                }
                Err(err) => panic!("Failed to connect to moonlink: {err:?}"),
            }
        };
        Mutex::new(stream)
    });
    STREAM.lock().unwrap()
}
