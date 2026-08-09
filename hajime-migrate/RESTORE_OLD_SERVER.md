# إعادة الخادم القديم من نسخة كاملة

هذا الملف يخصّ حالة واحدة: النظام الجديد على الجهاز، وشيء فيه خطأ، والقرار
هو العودة إلى ما كان. مصدره مجلد ينتجه `pull_server_image.sh`، وهو مستقل
تماماً عن `backup.sh` الذي يأخذ البيانات لا الجهاز.

الفرق بينهما ليس تفصيلاً. `backup.sh` يعطيك ما يملأ به النظام الجديد. هذا
الملف يعطيك الجهاز القديم نفسه: جدول أقسامه، وقطاع إقلاعه، ونظام ملفاته
الجذري، و`/vault` بكامله.

## ما في المجلد

| الملف | ما هو |
|---|---|
| `mbr-1MiB.img` | أول ميغابايت من القرص: MBR وجدول الأقسام والفجوة التي يسكنها المحمّل |
| `partition-table.sfdisk` | جدول الأقسام نصاً، احتياطاً ولقرص بحجم مختلف |
| `rootfs.tar.gz` | `/` كاملاً عدا `proc` و`sys` و`dev` و`run` و`tmp` و`mnt` و`media` و`vault` |
| `vault-data.tar.gz` | `/vault` عدا `docker` |
| `vault-docker.tar.gz` | `/vault/docker`: طبقات الحاويات وأحجامها |
| `lsblk.txt`, `fstab.txt` | الأقسام ومعرّفاتها، وهي مهمّة: `fstab` يركّب بالـUUID |
| `apk-world.txt`, `apk-installed.txt` | الحزم المطلوبة صراحةً، وكل ما كان مثبّتاً بإصداراته |
| `docker-*.txt`, `docker-inspect.json` | الحاويات وصورها وأحجامها وتفصيل تشغيلها |
| `rc-status.txt`, `root-crontab.txt`, `network.txt` | الخدمات المفعّلة، والمهام المجدولة، والعنونة |

## قبل أي شيء: هل النسخة سليمة

```bash
cd <مجلد-النسخة>
sha256sum -c SHA256SUMS
gzip -t rootfs.tar.gz vault-data.tar.gz vault-docker.tar.gz
```

`gzip -t` هو الفحص الذي يهم: gzip يخزّن CRC32 وطول البيانات الأصلية، فأرشيف
يجتازه أرشيف غير مبتور. لا تبدأ الاستعادة قبل أن يمرّ الأمران.

## الاستعادة

أقلع الجهاز من وسيط Alpine (الإصدار 3.23 أو أحدث؛ نواة الوسيط لا تهم هنا،
النواة المستعادة هي التي ستقلع). ثم:

**1. أعد شكل القرص.**

```bash
dd if=mbr-1MiB.img of=/dev/sda bs=1M count=1 conv=fsync
partprobe /dev/sda
```

هذا يعيد جدول الأقسام وشفرة الإقلاع معاً، لأن الاثنين داخل الميغابايت الأول.
إن كان القرص الجديد أصغر من 477 GB فلن يصلح: استخدم `sfdisk /dev/sda <
partition-table.sfdisk` بعد تعديل حجم `sda3`، ثم أعد كتابة أول 440 بايت فقط
من `mbr-1MiB.img` (شفرة الإقلاع دون الجدول):

```bash
dd if=mbr-1MiB.img of=/dev/sda bs=440 count=1 conv=fsync
```

**2. أنشئ أنظمة الملفات بنفس المعرّفات.**

`fstab` يركّب بالـUUID، فنظام ملفات بمعرّف جديد يعني جهازاً يقلع إلى
`emergency mode`. المعرّفات في `lsblk.txt`، وهذه هي:

```bash
mkfs.ext4 -U 8b924cc8-4c8c-4e9c-986e-9bf6b4742c79 /dev/sda1
mkswap    -U 3e9949e3-b42f-4734-bf80-0893d36a4b63 /dev/sda2
mkfs.ext4 -U 10e1f997-4e2e-4c51-b2ca-315a17017e7c /dev/sda3
```

**3. فكّ الأرشيفات.**

```bash
mount /dev/sda1 /mnt
mkdir -p /mnt/vault && mount /dev/sda3 /mnt/vault

tar -xzpf rootfs.tar.gz       -C /mnt        --numeric-owner
tar -xzpf vault-data.tar.gz   -C /mnt/vault  --numeric-owner
mkdir -p /mnt/vault/docker
tar -xzpf vault-docker.tar.gz -C /mnt/vault/docker --numeric-owner
```

`--numeric-owner` ضروري: وسيط الإقلاع لا يعرف مستخدمي الجهاز المستعاد، وبدونه
تُترجم الأرقام إلى أسماء خاطئة أو إلى root.

**4. أعد إنشاء المجلدات الافتراضية** التي استُثنيت لأنها ليست بيانات:

```bash
mkdir -p /mnt/proc /mnt/sys /mnt/dev /mnt/run /mnt/tmp /mnt/mnt /mnt/media
chmod 1777 /mnt/tmp
```

**5. ثبّت المحمّل** إن لم يقلع بعد الخطوة 1 (شفرة الميغابايت الأول تكفي عادةً،
لكن قسماً جديداً بموقع مختلف يحتاج إعادة كتابة):

```bash
mount --bind /dev /mnt/dev && mount -t proc none /mnt/proc && mount -t sysfs none /mnt/sys
chroot /mnt /bin/sh -c 'apk add --no-cache syslinux && dd if=/usr/share/syslinux/mbr.bin of=/dev/sda bs=440 count=1 && extlinux --install /boot'
```

**6. أعد التشغيل** بعد نزع الوسيط.

## بعد الإقلاع

الحاويات تعود وحدها إن كانت `docker` مفعّلة في `rc-status.txt`. تحقّق:

```bash
rc-status
docker ps --format '{{.Names}}\t{{.Status}}'
```

قارن القائمة بـ`docker-ps.txt`. الحاويات التسع عشرة كلها يجب أن تظهر.

## حدود يجب أن تعرفها قبل أن تعتمد على هذا

**النسخة أُخذت والخادم يعمل.** هي متسقة اتساق انقطاع تيار كهربائي: نفس الحالة
التي يتركها فصل الكهرباء فجأة. ext4 وطبقات الحاويات تتعافى من ذلك عبر
سجلّاتها، لكن قاعدة بيانات كانت في منتصف كتابة قد تعود إلى آخر نقطة اتساق لا
إلى آخر معاملة. لهذا تؤخذ القواعد منطقياً أيضاً بـ`backup.sh` عبر أدواتها.
استعد الجهاز من هنا، ثم حمّل القواعد من هناك إن لزم.

**الأرشيفات من busybox tar.** لا يخزّن الخصائص الممتدة ولا ACL ولا قدرات
الملفات. على Alpine هذا لا يظهر غالباً، لكن ملفاً كان يحمل capability
سيفقدها. إن ظهر أمر يشكو من صلاحيات بعد الاستعادة فهذا أول ما يُفحص.

**`/vault/ollama` بداخل النسخة** وحجمه 9.5 GB أوزان نماذج. إن كانت المساحة
ضيقة فهو أول ما يمكن استثناؤه، لأنه يُنزَّل مجدداً.

**النسخة صورة للحظة أُخذت فيها.** كل ما كتبه الخادم بعدها ليس فيها. إن كنت
ستنتقل إلى النظام الجديد فعلاً، خذ نسخة جديدة قبل الانتقال بساعات لا بأيام.
