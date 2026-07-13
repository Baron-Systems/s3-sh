#!/usr/bin/env bash

# ============================================================
# سكربت إعداد نسخ احتياطي يومي إلى S3 مع الاحتفاظ بآخر النسخ
# Production Ready — متوافق مع AWS S3, Contabo, Wasabi, MinIO
# يدعم: Ubuntu 20.04 / 22.04 / 24.04
# ============================================================

set -Eeuo pipefail
umask 077

# ==================================================
# إعدادات المستخدم — عدّل هذه القيم قبل تشغيل الملف
# ==================================================

S3_ACCESS_KEY="ضع_access_key_هنا"
S3_SECRET_KEY="ضع_secret_key_هنا"

S3_BUCKET="اسم-bucket"
S3_REGION="us-east-1"

# اتركه فارغاً عند استخدام Amazon AWS S3
# واستخدمه عند التعامل مع مزود S3 متوافق مثل Contabo أو Wasabi أو MinIO
S3_ENDPOINT_URL=""

# لـ MinIO أو بعض مزودي S3-compatible الذين لا يدعمون virtual-hosted style
# اجعل القيمة true. اتركها false لـ AWS S3 و Contabo و Wasabi
S3_PATH_STYLE="false"

# نوع النسخ الاحتياطي: path | mysql | postgres
BACKUP_MODE="path"

# المسار الكامل للملف أو المجلد المطلوب نسخه (يستخدم فقط عندما BACKUP_MODE=path)
SOURCE_PATH="/path/to/file-or-directory"

# إعدادات قاعدة البيانات (تستخدم فقط عندما BACKUP_MODE=mysql أو postgres)
DB_NAME=""
DB_USER=""
DB_PASSWORD=""
DB_HOST="localhost"
DB_PORT=""  # يترك فارغاً لاستخدام المنفذ الافتراضي (3306 لـ mysql، 5432 لـ postgres)

# المجلد داخل S3 الذي تحفظ فيه النسخ
S3_BACKUP_PREFIX="server-backups"

# وقت النسخ اليومي بنظام 24 ساعة
CRON_HOUR="2"
CRON_MINUTE="0"

# عدد النسخ التي يجب الاحتفاظ بها
KEEP_BACKUPS="3"

# مجلد الملفات المؤقتة (يجب أن يكون على قرص به مساحة كافية)
TEMP_DIR="/root/.s3-backup/tmp"

# ==================================================
# ثوابت النظام — لا تعدل ما يلي
# ==================================================

BACKUP_DIR="/root/.s3-backup"
CONFIG_FILE="$BACKUP_DIR/config"
BACKUP_SCRIPT="$BACKUP_DIR/backup.sh"
LOG_FILE="$BACKUP_DIR/backup.log"
LOCK_FILE="$BACKUP_DIR/backup.lock"
CRON_FILE="/etc/cron.d/s3-daily-backup"
LOGROTATE_FILE="/etc/logrotate.d/s3-backup"
HOSTNAME="$(hostname)"
S3_DEST_DIR="s3://${S3_BUCKET}/${S3_BACKUP_PREFIX}/${HOSTNAME}"

# الألوان لرسائل الطرفية
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# متغير لتخزين اسم النسخة التجريبية
TEST_BACKUP_NAME=""
TEST_BACKUP_SIZE=""

# ==================================================
# دوال مساعدة
# ==================================================

log_msg() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

error_exit() {
    echo -e "${RED}[خطأ]${NC} $1" >&2
    echo -e "${RED}راجع ملف السجل: $LOG_FILE${NC}" >&2
    exit 1
}

# -----------------------------------------------
# Improved Trap — يظهر: رقم السطر، الأمر الفاشل،
# رمز الخطأ، اسم الدالة، ملف السجل
# -----------------------------------------------
error_trap() {
    local line_no="$1"
    local failed_cmd="$2"
    local exit_code="$3"
    local func_stack="$4"

    if [[ "$exit_code" -eq 0 ]]; then
        return 0
    fi

    echo -e "${RED}========================================${NC}" >&2
    echo -e "${RED}حدث خطأ في السكربت${NC}" >&2
    echo -e "${RED}السطر: $line_no${NC}" >&2
    echo -e "${RED}الأمر: $failed_cmd${NC}" >&2
    echo -e "${RED}رمز الخطأ: $exit_code${NC}" >&2
    echo -e "${RED}الدالة: $func_stack${NC}" >&2
    echo -e "${RED}ملف السجل: $LOG_FILE${NC}" >&2
    echo -e "${RED}========================================${NC}" >&2

    rm -rf "$TEMP_DIR" 2>/dev/null || true
    exit "$exit_code"
}
trap 'error_trap $LINENO "$BASH_COMMAND" $? "${FUNCNAME[*]}"' ERR

# -----------------------------------------------
# بناء مصفوفة وسائط AWS بدون استخدام eval
# -----------------------------------------------
build_aws_args() {
    AWS_ARGS=()
    if [[ -n "${S3_ENDPOINT_URL// }" ]]; then
        AWS_ARGS+=(--endpoint-url "$S3_ENDPOINT_URL")
    fi
    if [[ "${S3_PATH_STYLE:-false}" == "true" ]]; then
        AWS_ARGS+=(--path-style)
    fi
}

# ==================================================
# التحقق من الصلاحيات والإعدادات
# ==================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error_exit "يجب تشغيل هذا السكربت بصلاحيات root. استخدم: sudo ./setup_s3_backup.sh"
    fi
}

validate_settings() {
    local has_error=0

    # التحقق من S3 credentials
    if [[ -z "${S3_ACCESS_KEY// }" ]] || [[ "$S3_ACCESS_KEY" == "ضع_access_key_هنا" ]]; then
        echo -e "${RED}[خطأ] S3_ACCESS_KEY غير مضبوط.${NC}" >&2
        has_error=1
    fi

    if [[ -z "${S3_SECRET_KEY// }" ]] || [[ "$S3_SECRET_KEY" == "ضع_secret_key_هنا" ]]; then
        echo -e "${RED}[خطأ] S3_SECRET_KEY غير مضبوط.${NC}" >&2
        has_error=1
    fi

    if [[ -z "${S3_BUCKET// }" ]] || [[ "$S3_BUCKET" == "اسم-bucket" ]]; then
        echo -e "${RED}[خطأ] S3_BUCKET غير مضبوط.${NC}" >&2
        has_error=1
    fi

    if [[ -z "${S3_REGION// }" ]]; then
        echo -e "${RED}[خطأ] S3_REGION غير مضبوط.${NC}" >&2
        has_error=1
    fi

    # التحقق من BACKUP_MODE
    case "$BACKUP_MODE" in
        path)
            if [[ -z "${SOURCE_PATH// }" ]] || [[ "$SOURCE_PATH" == "/path/to/file-or-directory" ]]; then
                echo -e "${RED}[خطأ] SOURCE_PATH غير مضبوط.${NC}" >&2
                has_error=1
            elif [[ ! -e "$SOURCE_PATH" ]]; then
                echo -e "${RED}[خطأ] المسار المحدد في SOURCE_PATH غير موجود: $SOURCE_PATH${NC}" >&2
                has_error=1
            fi
            ;;
        mysql)
            if [[ -z "${DB_NAME// }" ]]; then
                echo -e "${RED}[خطأ] DB_NAME غير مضبوط (مطلوب لوضع mysql).${NC}" >&2
                has_error=1
            fi
            if [[ -z "${DB_USER// }" ]]; then
                echo -e "${RED}[خطأ] DB_USER غير مضبوط (مطلوب لوضع mysql).${NC}" >&2
                has_error=1
            fi
            if [[ -z "${DB_PASSWORD// }" ]]; then
                echo -e "${RED}[خطأ] DB_PASSWORD غير مضبوط (مطلوب لوضع mysql).${NC}" >&2
                has_error=1
            fi
            ;;
        postgres)
            if [[ -z "${DB_NAME// }" ]]; then
                echo -e "${RED}[خطأ] DB_NAME غير مضبوط (مطلوب لوضع postgres).${NC}" >&2
                has_error=1
            fi
            if [[ -z "${DB_USER// }" ]]; then
                echo -e "${RED}[خطأ] DB_USER غير مضبوط (مطلوب لوضع postgres).${NC}" >&2
                has_error=1
            fi
            if [[ -z "${DB_PASSWORD// }" ]]; then
                echo -e "${RED}[خطأ] DB_PASSWORD غير مضبوط (مطلوب لوضع postgres).${NC}" >&2
                has_error=1
            fi
            ;;
        *)
            echo -e "${RED}[خطأ] BACKUP_MODE يجب أن يكون: path أو mysql أو postgres${NC}" >&2
            has_error=1
            ;;
    esac

    # ضبط المنفذ الافتراضي حسب نوع قاعدة البيانات
    if [[ -z "${DB_PORT// }" ]]; then
        case "$BACKUP_MODE" in
            mysql)    DB_PORT="3306" ;;
            postgres) DB_PORT="5432" ;;
        esac
    fi

    # التحقق من القيم الرقمية
    if ! [[ "$KEEP_BACKUPS" =~ ^[0-9]+$ ]] || [[ "$KEEP_BACKUPS" -le 0 ]]; then
        echo -e "${RED}[خطأ] KEEP_BACKUPS يجب أن يكون رقماً صحيحاً أكبر من صفر.${NC}" >&2
        has_error=1
    fi

    if ! [[ "$CRON_HOUR" =~ ^[0-9]+$ ]] || [[ "$CRON_HOUR" -lt 0 ]] || [[ "$CRON_HOUR" -gt 23 ]]; then
        echo -e "${RED}[خطأ] CRON_HOUR يجب أن يكون بين 0 و 23.${NC}" >&2
        has_error=1
    fi

    if ! [[ "$CRON_MINUTE" =~ ^[0-9]+$ ]] || [[ "$CRON_MINUTE" -lt 0 ]] || [[ "$CRON_MINUTE" -gt 59 ]]; then
        echo -e "${RED}[خطأ] CRON_MINUTE يجب أن يكون بين 0 و 59.${NC}" >&2
        has_error=1
    fi

    if [[ $has_error -eq 1 ]]; then
        exit 1
    fi
}

# ==================================================
# تثبيت الأدوات المطلوبة
# ==================================================

install_dependencies() {
    echo -e "${YELLOW}[*]${NC} التحقق من الأدوات المطلوبة..."

    local required=(aws tar gzip cron flock)
    local missing=()

    # إضافة أدوات قواعد البيانات حسب BACKUP_MODE
    case "$BACKUP_MODE" in
        mysql)    required+=(mysqldump) ;;
        postgres) required+=(pg_dump) ;;
    esac

    for tool in "${required[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            missing+=("$tool")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${YELLOW}[*]${NC} جاري تثبيت الأدوات الناقصة: ${missing[*]}"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq

        local packages=(awscli cron util-linux tar gzip)

        case "$BACKUP_MODE" in
            mysql)    packages+=(mysql-client) ;;
            postgres) packages+=(postgresql-client) ;;
        esac

        apt-get install -y -qq "${packages[@]}"
    else
        echo -e "${GREEN}[✓]${NC} جميع الأدوات المطلوبة متوفرة."
    fi

    # التأكد من تشغيل خدمة Cron
    if command -v systemctl &>/dev/null; then
        systemctl enable cron 2>/dev/null || systemctl enable crond 2>/dev/null || true
        systemctl start cron 2>/dev/null || systemctl start crond 2>/dev/null || true
    elif command -v service &>/dev/null; then
        service cron start 2>/dev/null || service crond start 2>/dev/null || true
    fi
}

# ==================================================
# إعداد ملفات النظام الآمنة
# ==================================================

setup_backup_dir() {
    echo -e "${YELLOW}[*]${NC} إنشاء مجلد النسخ الاحتياطي..."

    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"

    mkdir -p "$TEMP_DIR"
    chmod 700 "$TEMP_DIR"
}

write_config_file() {
    echo -e "${YELLOW}[*]${NC} كتابة ملف الإعدادات الآمن..."

    cat > "$CONFIG_FILE" <<EOF
# ملف إعدادات S3 — تم إنشاؤه تلقائياً
# لا تعرض محتوى هذا الملف ولا تشاركه
S3_ACCESS_KEY='$S3_ACCESS_KEY'
S3_SECRET_KEY='$S3_SECRET_KEY'
S3_BUCKET='$S3_BUCKET'
S3_REGION='$S3_REGION'
S3_ENDPOINT_URL='$S3_ENDPOINT_URL'
S3_PATH_STYLE='$S3_PATH_STYLE'
BACKUP_MODE='$BACKUP_MODE'
SOURCE_PATH='$SOURCE_PATH'
DB_NAME='$DB_NAME'
DB_USER='$DB_USER'
DB_PASSWORD='$DB_PASSWORD'
DB_HOST='$DB_HOST'
DB_PORT='$DB_PORT'
S3_BACKUP_PREFIX='$S3_BACKUP_PREFIX'
KEEP_BACKUPS='$KEEP_BACKUPS'
HOSTNAME='$HOSTNAME'
TEMP_DIR='$TEMP_DIR'
EOF

    chmod 600 "$CONFIG_FILE"
    echo -e "${GREEN}[✓]${NC} تم إنشاء ملف الإعدادات: $CONFIG_FILE"
}

# ==================================================
# إعداد logrotate
# ==================================================

setup_logrotate() {
    echo -e "${YELLOW}[*]${NC} إعداد logrotate لملف السجل..."

    cat > "$LOGROTATE_FILE" <<EOF
$LOG_FILE {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    create 0600 root root
    maxsize 50M
}
EOF

    chmod 644 "$LOGROTATE_FILE"
    echo -e "${GREEN}[✓]${NC} تم إنشاء ملف logrotate: $LOGROTATE_FILE"
}

# ==================================================
# كتابة سكربت النسخ الاحتياطي الفعلي
# ==================================================

write_backup_script() {
    echo -e "${YELLOW}[*]${NC} إنشاء سكربت النسخ الاحتياطي..."

    cat > "$BACKUP_SCRIPT" <<'BACKUP_EOF'
#!/usr/bin/env bash

# ============================================================
# سكربت النسخ الاحتياطي اليومي إلى S3
# Production Ready — لا تعدل هذا الملف مباشرة
# ============================================================

set -Eeuo pipefail
umask 077

# -----------------------------------------------
# تحميل الإعدادات
# -----------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "خطأ: ملف الإعدادات غير موجود: $CONFIG_FILE" >&2
    exit 1
fi
source "$CONFIG_FILE"

# تصدير بيانات اعتماد AWS CLI (مطلوبة لأوامر aws)
export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"
export AWS_DEFAULT_REGION="$S3_REGION"

# -----------------------------------------------
# الثوابت
# -----------------------------------------------
LOG_FILE="$SCRIPT_DIR/backup.log"
LOCK_FILE="$SCRIPT_DIR/backup.lock"
DATE_NOW="$(date +%Y-%m-%d_%H-%M-%S)"
BACKUP_NAME="backup-${DATE_NOW}.tar.gz"
LOCAL_BACKUP="$TEMP_DIR/$BACKUP_NAME"

# -----------------------------------------------
# بناء مصفوفة وسائط AWS (بدون eval)
# -----------------------------------------------
AWS_ARGS=()
if [[ -n "${S3_ENDPOINT_URL// }" ]]; then
    AWS_ARGS+=(--endpoint-url "$S3_ENDPOINT_URL")
fi
if [[ "${S3_PATH_STYLE:-false}" == "true" ]]; then
    AWS_ARGS+=(--path-style)
fi

S3_DEST_DIR="s3://${S3_BUCKET}/${S3_BACKUP_PREFIX}/${HOSTNAME}"
S3_KEY_PREFIX="${S3_BACKUP_PREFIX}/${HOSTNAME}"

# -----------------------------------------------
# دوال مساعدة
# -----------------------------------------------
log_msg() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# -----------------------------------------------
# Improved Trap
# -----------------------------------------------
error_trap() {
    local line_no="$1"
    local failed_cmd="$2"
    local exit_code="$3"
    local func_stack="$4"

    if [[ "$exit_code" -eq 0 ]]; then
        return 0
    fi

    log_msg "========================================"
    log_msg "حدث خطأ في سكربت النسخ الاحتياطي"
    log_msg "السطر: $line_no"
    log_msg "الأمر: $failed_cmd"
    log_msg "رمز الخطأ: $exit_code"
    log_msg "الدالة: $func_stack"
    log_msg "========================================"

    rm -f "$LOCAL_BACKUP"
    exit "$exit_code"
}
trap 'error_trap $LINENO "$BASH_COMMAND" $? "${FUNCNAME[*]}"' ERR

# -----------------------------------------------
# التنظيف عند الخروج
# -----------------------------------------------
cleanup() {
    rm -f "$LOCAL_BACKUP"
}
trap cleanup EXIT

# -----------------------------------------------
# منع تشغيل أكثر من نسخة في نفس الوقت
# -----------------------------------------------
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log_msg "خطأ: هناك نسخة أخرى من النسخ الاحتياطي تعمل حالياً"
    exit 1
fi

# -----------------------------------------------
# فحص المساحة الحرة
# -----------------------------------------------
check_disk_space() {
    local source_path="$1"
    local temp_dir="$2"

    local source_size
    source_size=$(du -sb "$source_path" 2>/dev/null | awk '{print $1}') || {
        log_msg "خطأ: فشل حساب حجم المصدر: $source_path"
        return 1
    }

    # إضافة 30% احتياطي للضغط والملفات المؤقتة
    local required_space=$((source_size + (source_size * 30 / 100)))

    local available_space
    available_space=$(df -B1 "$temp_dir" 2>/dev/null | awk 'NR==2 {print $4}') || {
        log_msg "خطأ: فشل حساب المساحة المتاحة في $temp_dir"
        return 1
    }

    if [[ "$available_space" -lt "$required_space" ]]; then
        log_msg "خطأ: مساحة غير كافية في $temp_dir"
        log_msg "المساحة المطلوبة: $(numfmt --to=iec $required_space 2>/dev/null || echo ${required_space} بايت)"
        log_msg "المساحة المتاحة: $(numfmt --to=iec $available_space 2>/dev/null || echo ${available_space} بايت)"
        return 1
    fi

    log_msg "المساحة كافية — مطلوب: $(numfmt --to=iec $required_space 2>/dev/null || echo ${required_space})، متاح: $(numfmt --to=iec $available_space 2>/dev/null || echo ${available_space})"
    return 0
}

# -----------------------------------------------
# إعادة المحاولة مع Exponential Backoff
# -----------------------------------------------
s3_upload_with_retry() {
    local source="$1"
    local dest="$2"
    local max_attempts=3
    local attempt=1
    local wait_time=5

    while [[ $attempt -le $max_attempts ]]; do
        if aws s3 cp "$source" "$dest" --region "$S3_REGION" "${AWS_ARGS[@]}"; then
            return 0
        fi
        if [[ $attempt -lt $max_attempts ]]; then
            log_msg "فشلت المحاولة $attempt/$max_attempts، إعادة المحاولة بعد ${wait_time} ثوان..."
            sleep "$wait_time"
            wait_time=$((wait_time * 2))
        fi
        ((attempt++))
    done
    return 1
}

s3_head_with_retry() {
    local key="$1"
    local max_attempts=3
    local attempt=1
    local wait_time=5

    while [[ $attempt -le $max_attempts ]]; do
        if aws s3api head-object --bucket "$S3_BUCKET" --key "$key" --region "$S3_REGION" "${AWS_ARGS[@]}" >/dev/null 2>&1; then
            return 0
        fi
        if [[ $attempt -lt $max_attempts ]]; then
            sleep "$wait_time"
            wait_time=$((wait_time * 2))
        fi
        ((attempt++))
    done
    return 1
}

# -----------------------------------------------
# التحقق من نجاح الرفع (وجود + تطابق الحجم)
# -----------------------------------------------
verify_upload() {
    local local_file="$1"
    local s3_key="$2"

    local local_size
    local_size=$(stat -c%s "$local_file" 2>/dev/null || stat -f%z "$local_file" 2>/dev/null)

    if [[ -z "$local_size" || "$local_size" -eq 0 ]]; then
        log_msg "خطأ: فشل قراءة حجم الملف المحلي"
        return 1
    fi

    local s3_size
    s3_size=$(aws s3api head-object \
        --bucket "$S3_BUCKET" \
        --key "$s3_key" \
        --query "ContentLength" \
        --output text \
        --region "$S3_REGION" \
        "${AWS_ARGS[@]}" 2>/dev/null) || {
        log_msg "خطأ: فشل التحقق من وجود النسخة على S3"
        return 1
    }

    if [[ -z "$s3_size" || "$s3_size" == "None" ]]; then
        log_msg "خطأ: النسخة غير موجودة على S3"
        return 1
    fi

    if [[ "$local_size" -ne "$s3_size" ]]; then
        log_msg "خطأ: حجم النسخة المحلية ($local_size بايت) لا يطابق حجم النسخة على S3 ($s3_size بايت)"
        return 1
    fi

    log_msg "تم التحقق: النسخة موجودة على S3 والحجم متطابق ($s3_size بايت)"
    return 0
}

# -----------------------------------------------
# حذف النسخ القديمة باستخدام s3api list-objects-v2
# والاعتماد على LastModified بدلاً من اسم الملف
# -----------------------------------------------
delete_old_backups() {
    log_msg "جاري تطبيق سياسة الاحتفاظ (الاحتفاظ بآخر $KEEP_BACKUPS نسخ)..."

    local objects
    objects=$(aws s3api list-objects-v2 \
        --bucket "$S3_BUCKET" \
        --prefix "${S3_KEY_PREFIX}/backup-" \
        --query "Contents[?ends_with(Key, '.tar.gz')].[Key,LastModified]" \
        --output text \
        --region "$S3_REGION" \
        "${AWS_ARGS[@]}" 2>/dev/null || true)

    if [[ -z "$objects" ]]; then
        log_msg "لا توجد نسخ احتياطية حالياً"
        return 0
    fi

    # ترتيب النسخ من الأحدث إلى الأقدم حسب LastModified
    mapfile -t sorted_keys < <(echo "$objects" | sort -k2 -r | awk '{print $1}')

    local total_count=${#sorted_keys[@]}
    log_msg "عدد النسخ الحالي: $total_count"

    if [[ "$total_count" -le "$KEEP_BACKUPS" ]]; then
        log_msg "لا توجد نسخ قديمة للحذف"
        return 0
    fi

    # حذف النسخ الزائدة (تخطي أول KEEP_BACKUPS نسخ الأحدث)
    for ((i = KEEP_BACKUPS; i < total_count; i++)); do
        local old_key="${sorted_keys[$i]}"
        log_msg "حذف النسخة القديمة: $old_key"
        if ! aws s3 rm "s3://${S3_BUCKET}/${old_key}" --region "$S3_REGION" "${AWS_ARGS[@]}" >/dev/null 2>&1; then
            log_msg "تحذير: فشل حذف $old_key"
        fi
    done

    log_msg "تم حذف النسخ القديمة (بقيت $KEEP_BACKUPS نسخ)"
}

# ==================================================
# بدء عملية النسخ الاحتياطي
# ==================================================

log_msg "========================================"
log_msg "بدء عملية النسخ الاحتياطي"
log_msg "النوع: $BACKUP_MODE"

mkdir -p "$TEMP_DIR"
chmod 700 "$TEMP_DIR"

# -----------------------------------------------
# إنشاء النسخة حسب BACKUP_MODE
# -----------------------------------------------
case "$BACKUP_MODE" in
    path)
        log_msg "المصدر: $SOURCE_PATH"
        log_msg "وجهة S3: $S3_DEST_DIR/"

        if [[ ! -e "$SOURCE_PATH" ]]; then
            log_msg "خطأ: المسار المصدر غير موجود: $SOURCE_PATH"
            exit 1
        fi

        check_disk_space "$SOURCE_PATH" "$TEMP_DIR" || exit 1

        SOURCE_DIR="$(dirname "$SOURCE_PATH")"
        SOURCE_BASE="$(basename "$SOURCE_PATH")"

        log_msg "جاري إنشاء الأرشيف: $BACKUP_NAME"
        cd "$SOURCE_DIR"
        tar -czf "$LOCAL_BACKUP" "$SOURCE_BASE" 2>/dev/null
        ;;

    mysql)
        log_msg "قاعدة البيانات: $DB_NAME@$DB_HOST:$DB_PORT"
        log_msg "وجهة S3: $S3_DEST_DIR/"

        log_msg "جاري تصدير قاعدة البيانات (mysqldump)..."
        if ! mysqldump \
            --host="$DB_HOST" \
            --port="$DB_PORT" \
            --user="$DB_USER" \
            --password="$DB_PASSWORD" \
            --single-transaction \
            --routines \
            --triggers \
            --events \
            --set-gtid-purged=OFF \
            "$DB_NAME" 2>/dev/null | gzip > "$LOCAL_BACKUP"; then
            log_msg "خطأ: فشل تصدير قاعدة البيانات"
            exit 1
        fi
        log_msg "تم تصدير وضغط قاعدة البيانات بنجاح"
        ;;

    postgres)
        log_msg "قاعدة البيانات: $DB_NAME@$DB_HOST:$DB_PORT"
        log_msg "وجهة S3: $S3_DEST_DIR/"

        log_msg "جاري تصدير قاعدة البيانات (pg_dump)..."
        if ! PGPASSWORD="$DB_PASSWORD" pg_dump \
            --host="$DB_HOST" \
            --port="$DB_PORT" \
            --username="$DB_USER" \
            --no-password \
            --no-owner \
            "$DB_NAME" 2>/dev/null | gzip > "$LOCAL_BACKUP"; then
            log_msg "خطأ: فشل تصدير قاعدة البيانات"
            exit 1
        fi
        log_msg "تم تصدير وضغط قاعدة البيانات بنجاح"
        ;;
esac

# -----------------------------------------------
# التحقق من إنشاء الملف المحلي
# -----------------------------------------------
if [[ ! -f "$LOCAL_BACKUP" ]]; then
    log_msg "خطأ: فشل إنشاء ملف النسخ الاحتياطي"
    exit 1
fi

local_size=$(stat -c%s "$LOCAL_BACKUP" 2>/dev/null || stat -f%z "$LOCAL_BACKUP" 2>/dev/null)
log_msg "تم إنشاء النسخة المحلية بنجاح (الحجم: ${local_size} بايت)"

# -----------------------------------------------
# رفع النسخة إلى S3 مع إعادة المحاولة
# -----------------------------------------------
log_msg "جاري الرفع إلى S3: $S3_DEST_DIR/$BACKUP_NAME"
if ! s3_upload_with_retry "$LOCAL_BACKUP" "$S3_DEST_DIR/$BACKUP_NAME"; then
    log_msg "خطأ: فشل رفع النسخة إلى S3 بعد كل المحاولات"
    exit 1
fi
log_msg "تم الرفع بنجاح"

# -----------------------------------------------
# التحقق من نجاح الرفع (وجود + تطابق الحجم)
# -----------------------------------------------
log_msg "جاري التحقق من النسخة على S3..."
if ! verify_upload "$LOCAL_BACKUP" "${S3_KEY_PREFIX}/${BACKUP_NAME}"; then
    log_msg "خطأ: فشل التحقق من النسخة على S3"
    exit 1
fi

# -----------------------------------------------
# حذف النسخ القديمة
# -----------------------------------------------
delete_old_backups

log_msg "انتهت عملية النسخ الاحتياطي بنجاح: $BACKUP_NAME"
log_msg "========================================"

# إخراج اسم النسخة ليتمكن سكربت الإعداد من التقاطه
echo "$BACKUP_NAME"

exit 0
BACKUP_EOF

    chmod 700 "$BACKUP_SCRIPT"
    echo -e "${GREEN}[✓]${NC} تم إنشاء سكربت النسخ: $BACKUP_SCRIPT"
}

# ==================================================
# إعداد Cron Job
# ==================================================

setup_cron() {
    echo -e "${YELLOW}[*]${NC} إعداد مهمة Cron اليومية..."

    local cron_line="${CRON_MINUTE} ${CRON_HOUR} * * * root ${BACKUP_SCRIPT} >> ${LOG_FILE} 2>&1"

    # التحقق من وجود نفس المهمة مسبقاً
    if [[ -f "$CRON_FILE" ]]; then
        local existing_line
        existing_line=$(grep -F "${BACKUP_SCRIPT}" "$CRON_FILE" 2>/dev/null || true)
        if [[ "$existing_line" == "$cron_line" ]]; then
            echo -e "${GREEN}[✓]${NC} مهمة Cron موجودة مسبقاً ولم تتغير."
            return 0
        fi
        echo -e "${YELLOW}[*]${NC} تم تغيير وقت Cron، جاري التحديث..."
    fi

    # كتابة ملف Cron
    echo "$cron_line" > "$CRON_FILE"
    echo "" >> "$CRON_FILE"

    chmod 644 "$CRON_FILE"
    chown root:root "$CRON_FILE"

    # التحقق من صحة تنسيق Cron (basic validation)
    if ! grep -qE '^[0-9]{1,2}\s+[0-9]{1,2}\s+\*\s+\*\s+\*\s+root\s+' "$CRON_FILE"; then
        echo -e "${RED}[خطأ]${NC} تنسيق ملف Cron غير صالح" >&2
        return 1
    fi

    # إعادة تشغيل Cron فقط عند الحاجة
    local cron_restarted=0
    if command -v systemctl &>/dev/null; then
        if systemctl is-active --quiet cron 2>/dev/null; then
            systemctl restart cron >/dev/null 2>&1 && cron_restarted=1
        elif systemctl is-active --quiet crond 2>/dev/null; then
            systemctl restart crond >/dev/null 2>&1 && cron_restarted=1
        fi
    elif command -v service &>/dev/null; then
        service cron restart >/dev/null 2>&1 && cron_restarted=1
        service crond restart >/dev/null 2>&1 && cron_restarted=1
    fi

    if [[ "$cron_restarted" -eq 1 ]]; then
        echo -e "${GREEN}[✓]${NC} تم إعادة تشغيل خدمة Cron"
    fi

    echo -e "${GREEN}[✓]${NC} تم إنشاء/تحديث مهمة Cron: $CRON_FILE"
}

# ==================================================
# تنفيذ نسخة تجريبية لحظية
# ==================================================

run_test_backup() {
    echo -e "${YELLOW}[*]${NC} تنفيذ نسخة تجريبية لحظية..."
    echo ""

    local output
    if ! output=$("$BACKUP_SCRIPT" 2>&1); then
        echo -e "${RED}[خطأ]${NC} فشل تنفيذ النسخة التجريبية" >&2
        echo "$output" >&2
        return 1
    fi

    # استخراج BACKUP_NAME من آخر سطر في stdout
    TEST_BACKUP_NAME=$(echo "$output" | tail -n 1)

    if [[ -z "$TEST_BACKUP_NAME" ]]; then
        echo -e "${RED}[خطأ]${NC} لم يتم الحصول على اسم النسخة من سكربت النسخ" >&2
        return 1
    fi

    # تصدير بيانات اعتماد AWS CLI
    export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
    export AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"
    export AWS_DEFAULT_REGION="$S3_REGION"

    # الحصول على حجم النسخة من S3
    build_aws_args
    TEST_BACKUP_SIZE=$(aws s3api head-object \
        --bucket "$S3_BUCKET" \
        --key "${S3_BACKUP_PREFIX}/${HOSTNAME}/${TEST_BACKUP_NAME}" \
        --query "ContentLength" \
        --output text \
        --region "$S3_REGION" \
        "${AWS_ARGS[@]}" 2>/dev/null || echo "غير معروف")

    if [[ "$TEST_BACKUP_SIZE" =~ ^[0-9]+$ ]]; then
        TEST_BACKUP_SIZE="$(numfmt --to=iec "$TEST_BACKUP_SIZE" 2>/dev/null || echo "${TEST_BACKUP_SIZE} بايت")"
    fi

    echo ""
    echo -e "${GREEN}[✓]${NC} تم رفع النسخة التجريبية بنجاح: $TEST_BACKUP_NAME"
    return 0
}

# ==================================================
# عرض أوامر مساعدة في النهاية
# ==================================================

show_helper_commands() {
    build_aws_args

    echo ""
    echo "أوامر مفيدة:"
    echo "  تشغيل نسخة يدوياً:"
    echo "    sudo $BACKUP_SCRIPT"
    echo ""
    echo "  عرض السجل:"
    echo "    sudo tail -f $LOG_FILE"
    echo ""
    echo "  عرض إعدادات Cron:"
    echo "    sudo cat $CRON_FILE"
    echo ""
    echo "  عرض النسخ على S3:"
    echo "    aws s3 ls $S3_DEST_DIR/ --region $S3_REGION ${AWS_ARGS[*]}"
}

# ==================================================
# الرسالة النهائية
# ==================================================

print_success() {
    local backup_mode_label
    case "$BACKUP_MODE" in
        path)     backup_mode_label="ملف/مجلد (path)" ;;
        mysql)    backup_mode_label="MySQL Database" ;;
        postgres) backup_mode_label="PostgreSQL Database" ;;
        *)        backup_mode_label="$BACKUP_MODE" ;;
    esac

    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}تم إعداد النسخ الاحتياطي بنجاح${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo "نوع النسخ: $backup_mode_label"
    echo "اسم النسخة التجريبية: $TEST_BACKUP_NAME"
    echo "حجم النسخة التجريبية: $TEST_BACKUP_SIZE"
    echo "موعد النسخ اليومي: $(printf '%02d:%02d' "$CRON_HOUR" "$CRON_MINUTE")"
    echo "عدد النسخ المحتفظ بها: $KEEP_BACKUPS"
    echo "مسار S3 الكامل: $S3_DEST_DIR/"
    if [[ "$BACKUP_MODE" == "path" ]]; then
        echo "المصدر المحلي: $SOURCE_PATH"
    else
        echo "قاعدة البيانات: $DB_NAME@$DB_HOST:$DB_PORT"
    fi
    echo "ملف السجل: $LOG_FILE"
    echo "ملف Cron: $CRON_FILE"
    echo -e "${GREEN}========================================${NC}"
}

print_failure() {
    echo ""
    echo -e "${RED}========================================${NC}" >&2
    echo -e "${RED}فشلت عملية النسخ الاحتياطي التجريبية${NC}" >&2
    echo -e "${RED}========================================${NC}" >&2
    echo "تم إعداد/تحديث Cron: $CRON_FILE" >&2
    echo "سبب الفشل: $1" >&2
    echo "ملف السجل: $LOG_FILE" >&2
    echo -e "${RED}========================================${NC}" >&2
}

# ==================================================
# نقطة الدخول الرئيسية
# ==================================================

main() {
    echo -e "${YELLOW}[*]${NC} بدء إعداد النسخ الاحتياطي إلى S3..."
    echo ""

    check_root
    validate_settings
    build_aws_args
    install_dependencies
    setup_backup_dir
    write_config_file
    setup_logrotate
    write_backup_script
    setup_cron

    if run_test_backup; then
        print_success
        show_helper_commands
        exit 0
    else
        print_failure "فشل رفع أو التحقق من النسخة التجريبية على S3"
        show_helper_commands
        exit 1
    fi
}

main "$@"
