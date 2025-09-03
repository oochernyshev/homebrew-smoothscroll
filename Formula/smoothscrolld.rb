class Smoothscrolld < Formula
  desc "Background daemon for smooth mouse scrolling on macOS"
  homepage "https://github.com/oochernyshev/homebrew-smoothscroll"
  url "https://github.com/oochernyshev/homebrew-smoothscroll/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "<fill-in-sha256>"
  license "MIT"

  depends_on :macos
  depends_on xcode: ["15.0", :build]

  def install
    system "swift", "build", "-c", "release"
    bin.install ".build/release/smoothscrolld"
  end

  service do
    run [opt_bin/"smoothscrolld"]
    keep_alive true
    log_path var/"log/smoothscrolld.log"
    error_log_path var/"log/smoothscrolld.log"
  end

  test do
    # Verify binary runs and exits cleanly when asked for help
    system "#{bin}/smoothscrolld", "--help"
  end
end
