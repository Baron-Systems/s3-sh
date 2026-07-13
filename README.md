# S3 Backup System — Production Ready

سكربت Bash احترافي لإنشاء نظام نسخ احتياطي يومي إلى S3 مع رفع نسخة تجريبية مباشرة بعد الإعداد.

## الميزات

- **نسخ احتياطي يومي تلقائي** عبر Cron Job
- **دعم 3 أنواع**: ملف/مجلد (`path`)، MySQL (`mysql`)، PostgreSQL (`postgres`)
- **توافق كامل** مع AWS S3 و Contabo Object Storage و Wasabi و MinIO
- **تحقق ثلاثي** من نجاح الرفع (وجود + حجم + تطابق)
- **حذف تلقائي** للنسخ القديمة مع الاحتفاظ بآخر `N` نسخ
- **إعادة محاولة تلقائية** عند فشل الشبكة مع Exponential Backoff
- **فحص المساحة الحرة** قبل إنشاء الأرشيف
- **logrotate** لإدارة السجلات تلقائياً
- **أمان عالي**: `umask 077`، `chmod 600`، عدم طباعة المفاتيح في السجلات
- **يدعم**: Ubuntu 20.04 / 22.04 / 24.04

---

## المتطلبات

- Ubuntu 20.04 أو 22.04 أو 24.04
- صلاحيات `root` (يتم التحقق تلقائياً)
- حساب S3 متوافق (AWS S3 / Contabo / Wasabi / MinIO)
- اتصال إنترنت

---

## طريقة الاستخدام — نسخة واحدة

### 0. استنساخ المستودع

```bash
git clone https://github.com/your-username/s3-sh.git
cd s3-sh
```

### 1. تعديل الإعدادات

افتح الملف وعدّل المتغيرات في الأعلى:

```bash
nano setup_s3_backup.sh
```

**أمثلة للإعدادات:**

#### نسخ ملف أو مجلد:
```bash
S3_ACCESS_KEY="AKIAIOSFODNN7EXAMPLE"
S3_SECRET_KEY="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
S3_BUCKET="my-backups"
S3_REGION="us-east-1"
S3_ENDPOINT_URL=""                         # اتركه فارغاً لـ AWS S3

BACKUP_MODE="path"
SOURCE_PATH="/var/www/my-website"

S3_BACKUP_PREFIX="server-backups"
CRON_HOUR="3"
CRON_MINUTE="0"
KEEP_BACKUPS="7"
```

#### نسخ قاعدة بيانات MySQL:
```bash
BACKUP_MODE="mysql"
DB_NAME="my_database"
DB_USER="root"
DB_PASSWORD="MySecretPassword123"
DB_HOST="localhost"
DB_PORT=""                                  # سيستخدم 3306 تلقائياً
```

#### نسخ قاعدة بيانات PostgreSQL:
```bash
BACKUP_MODE="postgres"
DB_NAME="my_database"
DB_USER="postgres"
DB_PASSWORD="MySecretPassword123"
DB_HOST="localhost"
DB_PORT=""                                  # سيستخدم 5432 تلقائياً
```

#### استخدام مزود S3 متوافق (Contabo / Wasabi / MinIO):
```bash
S3_ENDPOINT_URL="https://eu2.contabostorage.com"
# أو
S3_ENDPOINT_URL="https://s3.wasabisys.com"
# أو
S3_ENDPOINT_URL="https://minio.example.com"
```

### 2. تشغيل السكربت

```bash
sudo bash setup_s3_backup.sh
```

سينفذ السكربت:
1. تثبيت الأدوات المطلوبة تلقائياً
2. إنشاء ملف الإعدادات الآمن
3. إنشاء سكربت النسخ الاحتياطي
4. إعداد مهمة Cron اليومية
5. تنفيذ نسخة تجريبية فورية والتحقق منها

---

## تشغيل السكربت أكثر من مرة لنسخ ملفين مختلفين

يمكنك استخدام **نفس ملف السكربت** لإنشاء أكثر من مهمة نسخ احتياطي. المفتاح هو تغيير `S3_BACKUP_PREFIX` في كل مرة لتجنب تداخل النسخ.

### الطريقة: نسخ الملف وتعديل الإعدادات

#### المهمة الأولى — نسخ موقع إلكتروني:
```bash
# انسخ الملف
cp setup_s3_backup.sh setup_backup_website.sh

# عدّل الإعدادات
nano setup_backup_website.sh
```

```bash
BACKUP_MODE="path"
SOURCE_PATH="/var/www/my-website"
S3_BACKUP_PREFIX="website-backups"          # مجلد منفصل في S3
CRON_HOUR="2"
CRON_MINUTE="0"
KEEP_BACKUPS="7"
```

```bash
sudo bash setup_backup_website.sh
```

#### المهمة الثانية — نسخ قاعدة بيانات:
```bash
# انسخ الملف
cp setup_s3_backup.sh setup_backup_database.sh

# عدّل الإعدادات
nano setup_backup_database.sh
```

```bash
BACKUP_MODE="mysql"
DB_NAME="my_database"
DB_USER="root"
DB_PASSWORD="MySecretPassword123"
S3_BACKUP_PREFIX="database-backups"         # مجلد منفصل في S3
CRON_HOUR="4"
CRON_MINUTE="30"
KEEP_BACKUPS="14"
```

```bash
sudo bash setup_backup_database.sh
```

### الهيكل الناتج على S3:

```
s3://my-backups/
├── website-backups/
│   └── my-server/
│       ├── backup-2026-07-13_02-00-00.tar.gz
│       └── backup-2026-07-12_02-00-00.tar.gz
├── database-backups/
│   └── my-server/
│       ├── backup-2026-07-13_04-30-00.tar.gz
│       └── backup-2026-07-12_04-30-00.tar.gz
└── server-backups/
    └── my-server/
        └── ...
```

### قواعد مهمة عند التشغيل المتعدد:

| المتغير | القاعدة |
|---------|---------|
| `S3_BACKUP_PREFIX` | **يجب تغييره** لكل مهمة — وإلا ستتداخل النسخ |
| `CRON_HOUR` / `CRON_MINUTE` | **يُفضّل تغييره** — لتوزيع الضغط على الشبكة |
| `KEEP_BACKUPS` | يمكن تخصيصه لكل مهمة على حدة |
| `S3_BUCKET` | يمكن استخدام نفس الباكت أو باكت مختلف |
| `S3_ACCESS_KEY` / `S3_SECRET_KEY` | نفس المفاتيح إذا كان نفس المزود |

---

## الملفات التي ينشئها السكربت

| الملف | الوصف |
|-------|-------|
| `/root/.s3-backup/config` | ملف الإعدادات (محمي بـ `chmod 600`) |
| `/root/.s3-backup/backup.sh` | سكربت النسخ الاحتياطي الفعلي |
| `/root/.s3-backup/backup.log` | ملف السجل |
| `/root/.s3-backup/tmp/` | مجلد الملفات المؤقتة |
| `/etc/cron.d/s3-daily-backup` | مهمة Cron اليومية |
| `/etc/logrotate.d/s3-backup` | إعدادات تدوير السجل |

---

## أوامر مفيدة بعد الإعداد

```bash
# تشغيل نسخة يدوياً
sudo /root/.s3-backup/backup.sh

# عرض السجل مباشرة
sudo tail -f /root/.s3-backup/backup.log

# عرض آخر 50 سطر من السجل
sudo tail -n 50 /root/.s3-backup/backup.log

# عرض مهمة Cron
sudo cat /etc/cron.d/s3-daily-backup

# عرض النسخ على S3
aws s3 ls s3://my-backups/website-backups/my-server/ --region us-east-1

# إعادة تشغيل الإعداد (يحدّث Cron إذا تغير الوقت فقط)
sudo bash setup_s3_backup.sh
```

---

## إعادة تشغيل السكربت بأمان

السكربت آمن عند إعادة تشغيله:
- **لا يكرر** مهمة Cron
- **يحدّث** وقت Cron فقط إذا تغير
- **لا يعيد** تثبيت الأدوات إذا كانت موجودة
- **ينفذ** نسخة تجريبية جديدة في كل مرة

---

## استكشاف الأخطاء

| المشكلة | الحل |
|---------|------|
| `S3_ACCESS_KEY غير مضبوط` | تأكد من تعبئة جميع المتغيرات في الأعلى |
| `المسار المصدر غير موجود` | تأكد من صحة `SOURCE_PATH` وأن الملف/المجلد موجود |
| `فشل رفع النسخة إلى S3` | تحقق من صحة المفاتيح، المنطقة، والـ endpoint |
| `مساحة غير كافية` | غير `TEMP_DIR` إلى قرص به مساحة أكبر |
| `هناك نسخة أخرى تعمل` | انتظر حتى تنتهي النسخة الحالية (الحظر عبر `flock`) |

---

## ملاحظات الأمان

- ملف الإعدادات `/root/.s3-backup/config` محمي بـ `chmod 600` ولا يمكن قراءته إلا من `root`
- لا تتم طباعة مفاتيح S3 أو كلمات مرور قواعد البيانات في السجلات
- جميع الملفات المؤقتة تُحذف تلقائياً بعد انتهاء النسخ
- كلمة مرور PostgreSQL تمرر عبر متغير بيئة (`PGPASSWORD`) فلا تظهر في `ps`
