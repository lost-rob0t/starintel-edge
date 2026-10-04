package actor.starintel.edge.service;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;

/** Copies packaged code only; preserves init.lisp and all state outside lisp/ecl.
 * No network, external directory or peer-supplied path is accepted by this installer.
 */
public final class RuntimeAssets implements EclLifecycle.Assets {
    public interface Source {
        String[] list(String path) throws IOException;
        InputStream open(String path) throws IOException;
    }
    private final Source source;
    private long bytes;
    private int files;
    public RuntimeAssets(Source source) { this.source = source; }
    @Override public void install(File destination, LocalRuntimeBackend.Cancellation cancellation) throws Exception {
        bytes = 0; files = 0;
        Path root = destination.toPath();
        if (Files.isSymbolicLink(root)) throw new IOException("Private runtime root is a symlink");
        Files.createDirectories(root);
        // Clear only generated code trees before recopying, so old versions cannot enter ASDF.
        // A crash during extraction cannot execute a partial tree; open() waits for all copies.
        clearGenerated(root.resolve("lisp"));
        clearGenerated(root.resolve("ecl"));
        // Operator init/outbox are outside these generated subtrees and remain untouched.
        copy("starintel-edge/lisp", root.resolve("lisp"), 0, cancellation);
        copy("starintel-edge/ecl", root.resolve("ecl"), 0, cancellation);
        if (!Files.isRegularFile(root.resolve("lisp/startup.lisp"), LinkOption.NOFOLLOW_LINKS))
            throw new IOException("Packaged runtime startup missing");
    }
    private void clearGenerated(Path directory) throws IOException {
        if (!Files.exists(directory, LinkOption.NOFOLLOW_LINKS)) return;
        if (Files.isSymbolicLink(directory)) throw new IOException("Generated root is a symlink");
        try (java.util.stream.Stream<Path> paths = Files.walk(directory, 34)) {
            Path[] entries = paths.limit(10002).sorted(java.util.Comparator.reverseOrder()).toArray(Path[]::new);
            if (entries.length > 10001) throw new IOException("Too many stale runtime files");
            for (Path entry : entries) Files.delete(entry); // walk does not follow symlinks.
        }
    }
    private void copy(String asset, Path destination, int depth, LocalRuntimeBackend.Cancellation cancel) throws Exception {
        cancel.check();
        if (depth > 32 || Files.isSymbolicLink(destination)) throw new IOException("Invalid runtime asset path");
        String[] children = source.list(asset);
        if (children != null && children.length > 0) {
            Files.createDirectories(destination);
            for (String child : children) {
                if (child.isEmpty() || child.equals(".") || child.equals("..")
                        || child.contains("/") || child.contains("\\")) throw new IOException("Invalid packaged asset name");
                copy(asset + "/" + child, destination.resolve(child), depth + 1, cancel);
            }
            return;
        }
        if (++files > 10000) throw new IOException("Too many runtime assets");
        Files.createDirectories(destination.getParent());
        Path temporary = Files.createTempFile(destination.getParent(), "edge-asset-", ".pending");
        long fileBytes = 0;
        try {
            try (InputStream input = source.open(asset); FileOutputStream output = new FileOutputStream(temporary.toFile())) {
                byte[] buffer = new byte[8192];
                int count;
                while ((count = input.read(buffer)) != -1) {
                    cancel.check();
                    bytes += count; fileBytes += count;
                    if (fileBytes > 32L * 1024 * 1024 || bytes > 256L * 1024 * 1024)
                        throw new IOException("Runtime assets exceed bounds");
                    output.write(buffer, 0, count);
                }
                output.getFD().sync();
            }
            Files.move(temporary, destination, StandardCopyOption.REPLACE_EXISTING);
        } finally { Files.deleteIfExists(temporary); }
    }
}
