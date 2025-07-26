#!/bin/bash

# Script Backup dengan Error Handling dan Logging
# Usage: ./backup_script.sh [IP_SERVER] [DIRECTORY]

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Konfigurasi
LOG_FILE="/var/log/backup_$(date +"%Y%m%d").log"
BACKUP_DIR="/backup"
TEMP_DIR="/tmp/backup"
GPG_RECIPIENT="admin@yourdomain.com"  # Ganti dengan email yang valid
NODE2_SERVER="node2"

# Fungsi logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Fungsi error handling
error_exit() {
    log "ERROR: $1"
    cleanup
    exit 1
}

# Fungsi cleanup
cleanup() {
    log "Membersihkan file temporary..."
    rm -rf "$TEMP_DIR"/*
    # Jangan hapus file backup yang sudah terenkripsi kecuali sudah berhasil disync
}

# Fungsi progress bar
progress_bar() {
    local progress=$1
    local width=50
    local filled=$((progress * width / 100))
    local empty=$((width - filled))
    
    printf "\r["
    printf "%*s" $filled | tr ' ' '='
    printf "%*s" $empty | tr ' ' '-'
    printf "] %d%%" $progress
}

# Validasi parameter input
if [ $# -ne 2 ]; then
    echo "Usage: $0 <IP_SERVER> <DIRECTORY>"
    exit 1
fi

server=$1
sourcedir=$2

# Validasi format IP (basic)
if ! [[ $server =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    error_exit "Format IP server tidak valid: $server"
fi

# Buat nama file backup dengan format yang benar
filename="backup_${server}_$(date +"%y%m%d%H%M%S").tar.gz"

log "[ PROSES BACKUP FILE DIMULAI ]"
log "Server: $server"
log "Source Directory: $sourcedir"
log "Backup Filename: $filename"

# Buat direktori yang diperlukan
mkdir -p "$BACKUP_DIR" "$TEMP_DIR"

# Validasi GPG key
log "Validating GPG key..."
if ! gpg --list-keys "$GPG_RECIPIENT" > /dev/null 2>&1; then
    error_exit "GPG key untuk email '$GPG_RECIPIENT' tidak ditemukan. Silakan import key terlebih dahulu dengan: gpg --import public_key.asc"
fi

# Test koneksi ke server source
log "Testing koneksi ke server source..."
if ! ssh -o ConnectTimeout=10 -o BatchMode=yes root@"$server" "test -d $sourcedir"; then
    error_exit "Tidak dapat terhubung ke server $server atau direktori $sourcedir tidak ditemukan"
fi

# Test koneksi ke node2
log "Testing koneksi ke node2..."
if ! ssh -o ConnectTimeout=10 -o BatchMode=yes root@"$NODE2_SERVER" "test -d /backup"; then
    error_exit "Tidak dapat terhubung ke server $NODE2_SERVER atau direktori /backup tidak ditemukan"
fi

# Tahap 1: Proses Sinkronisasi
log "Tahap 1: Memulai sinkronisasi dari server source..."
if ! rsync -av --progress root@"$server":"$sourcedir"/ "$TEMP_DIR"/; then
    error_exit "Rsync dari server source gagal"
fi
progress_bar 20
sleep 1

# Cek apakah ada file yang tersinkronisasi
if [ -z "$(ls -A $TEMP_DIR)" ]; then
    error_exit "Tidak ada file yang berhasil disinkronisasi"
fi

progress_bar 30
log "Sinkronisasi selesai. Ukuran data: $(du -sh $TEMP_DIR | cut -f1)"

# Tahap 2: Proses Kompresi
log "Tahap 2: Memulai kompresi..."
if ! tar -czf "$BACKUP_DIR/$filename" -C "$TEMP_DIR" .; then
    error_exit "Kompresi tar gagal"
fi
progress_bar 60
sleep 1

# Verifikasi file backup
if [ ! -f "$BACKUP_DIR/$filename" ] || [ ! -s "$BACKUP_DIR/$filename" ]; then
    error_exit "File backup tidak ditemukan atau kosong: $BACKUP_DIR/$filename"
fi

log "Kompresi selesai. Ukuran file backup: $(du -sh $BACKUP_DIR/$filename | cut -f1)"

# Tahap 3: Proses enkripsi
log "Tahap 3: Memulai enkripsi..."
# Cek trust level key sebelum enkripsi
if ! gpg --list-keys --with-colons "$GPG_RECIPIENT" | grep -q "^uid.*:.*f:"; then
    log "WARNING: GPG key belum fully trusted. Menggunakan --trust-model always"
fi

if ! gpg --trust-model always --cipher-algo AES256 -r "$GPG_RECIPIENT" --compress-algo 1 --compress-level 6 --armor -e "$BACKUP_DIR/$filename"; then
    error_exit "Enkripsi GPG gagal. Periksa apakah GPG key valid dan dapat digunakan"
fi

# Verifikasi file terenkripsi
encrypted_file="$BACKUP_DIR/$filename.asc"
if [ ! -f "$encrypted_file" ] || [ ! -s "$encrypted_file" ]; then
    error_exit "File terenkripsi tidak ditemukan atau kosong"
fi

# Hapus file backup yang belum terenkripsi setelah enkripsi berhasil
rm -f "$BACKUP_DIR/$filename"
progress_bar 80
sleep 1

log "Enkripsi selesai. Ukuran file terenkripsi: $(du -sh $encrypted_file | cut -f1)"

# Tahap 4: Proses sinkronisasi ke node2
log "Tahap 4: Memulai sinkronisasi ke node2..."
if ! rsync -av --progress "$encrypted_file" root@"$NODE2_SERVER":/backup/; then
    error_exit "Rsync ke node2 gagal"
fi
progress_bar 90
sleep 1

# Verifikasi file di node2
encrypted_filename=$(basename "$encrypted_file")
if ! ssh root@"$NODE2_SERVER" "test -f /backup/$encrypted_filename && test -s /backup/$encrypted_filename"; then
    error_exit "Verifikasi file di node2 gagal"
fi

log "Sinkronisasi ke node2 selesai"

# Tahap 5: Cleanup
log "Tahap 5: Membersihkan file temporary..."
rm -rf "$TEMP_DIR"/*

# Hapus file backup lokal hanya setelah konfirmasi berhasil di node2
rm -f "$encrypted_file"
progress_bar 100
echo -ne '\n'

log "[ PROSES BACKUP SELESAI ]"
log "File backup berhasil disimpan di node2: /backup/$encrypted_filename"

# Opsional: Kirim notifikasi email
# echo "Backup completed successfully for $server:$sourcedir" | mail -s "Backup Success" admin@domain.com