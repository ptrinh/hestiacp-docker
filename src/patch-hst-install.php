#!/usr/bin/env php
<?php
/**
 * Patch the HestiaCP installer so it works without systemd inside Docker.
 *
 * The installer runs `apt-get upgrade`, which reinstalls the real systemd
 * `systemctl` binary and clobbers our shim. After every such point we re-link
 * our shim back into place so the installer's later `systemctl` calls keep
 * hitting the replacement instead of a dead systemd.
 *
 * Based on Steveorevo/hestiacp-dockered.
 */

function patch_file($file, $search, $replace) {
    if (!file_exists($file)) { return; }
    $content = file_get_contents($file);
    if (strpos($content, $replace) !== false) { return; } // already patched
    if (strpos($content, $search) === false) {
        echo "WARN: anchor not found in $file (installer format changed?)\n";
        return;
    }
    file_put_contents($file, str_replace($search, $replace, $content));
    echo "Patched $file\n";
}

$relink = "rm /usr/bin/systemctl || true\nln -s /usr/bin/systemctl.sh /usr/bin/systemctl\n";

$installer = $argv[1] ?? '/usr/src/hst-install-ubuntu.sh';

patch_file($installer,
    "# Update apt repository\napt-get -qq update\n",
    "# Update apt repository\napt-get -qq update\n" . $relink
);
patch_file($installer,
    "apt-get -y upgrade >> \$LOG &\nBACK_PID=\$!\n",
    "apt-get -y upgrade >> \$LOG &\nBACK_PID=\$!\n" . $relink
);
