package actor.starintel.edge.service;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;

/** Preserves operator-owned Lisp. No request data, credentials or peers are generated here. */
public final class PrivateInitFile {
    private PrivateInitFile() {}
    public static synchronized File ensure(File directory, byte[] template) throws IOException {
        Path root = directory.toPath();
        if (Files.isSymbolicLink(root)) throw new IOException("Private runtime root is a symlink");
        Files.createDirectories(root);
        Path target = root.resolve("init.lisp");
        if (Files.exists(target, LinkOption.NOFOLLOW_LINKS)) return checked(target);
        Path temporary = Files.createTempFile(root, "init-", ".pending");
        try {
            try (FileOutputStream out = new FileOutputStream(temporary.toFile())) {
                out.write(template);
                out.getFD().sync();
            }
            // Same-directory move, without REPLACE_EXISTING. Never overwrite an existing init.
            try { Files.move(temporary, target); }
            catch (java.nio.file.FileAlreadyExistsException race) { /* Existing user file wins. */ }
            return checked(target);
        } finally { Files.deleteIfExists(temporary); }
    }
    private static File checked(Path target) throws IOException {
        if (!Files.isRegularFile(target, LinkOption.NOFOLLOW_LINKS) || Files.size(target) > 1024 * 1024)
            throw new IOException("init.lisp must be a regular app-private file, at most 1 MiB");
        return target.toFile();
    }
}
