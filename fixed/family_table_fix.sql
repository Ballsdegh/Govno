-- ============================================================
--  ПОЧИНКА ТАБЛИЦЫ `family`
-- ============================================================
--  Выполни это в phpMyAdmin / консоли MySQL на своей базе ПЕРЕД
--  запуском сервера с новым family_gui.pwn.
--
--  Зачем: таблица `family` нигде не создаётся геймодом (в коде нет
--  ни одного CREATE TABLE для неё) — она пришла из дампа. Если в ней
--  часть колонок объявлена NOT NULL без DEFAULT, то MySQL в режиме
--  STRICT_TRANS_TABLES (включён по умолчанию с версии 5.7) отклоняет
--  INSERT, где эти колонки не перечислены, с ошибкой 1364.
--  Именно это и давало «Ошибка создания семьи».
--
--  Скрипт безопасен: он только проставляетDEFAULT-значения,
--  данные существующих семей не трогает.
-- ============================================================

-- 1. Сначала посмотри текущую структуру и сравни с ожидаемой:
--    SHOW CREATE TABLE `family`;
--    SHOW VARIABLES LIKE 'sql_mode';

-- 2. Проставляем DEFAULT всем колонкам, которые заполняет создание семьи.
--    Если какой-то колонки в твоей таблице нет — ALTER на неё выдаст
--    ошибку 1054, тогда закомментируй эту строку и добавь колонку
--    через ADD COLUMN (см. блок 3 ниже).

ALTER TABLE `family`
    MODIFY `name`         VARCHAR(64)  NOT NULL DEFAULT '',
    MODIFY `u_id`         INT(11)      NOT NULL DEFAULT 0,
    MODIFY `time`         INT(11)      NOT NULL DEFAULT 0,
    MODIFY `color`        INT(11)      NOT NULL DEFAULT 0,
    MODIFY `level`        INT(11)      NOT NULL DEFAULT 1,
    MODIFY `exp`          INT(11)      NOT NULL DEFAULT 0,
    MODIFY `rank1`        VARCHAR(32)  NOT NULL DEFAULT '1 ранг',
    MODIFY `rank2`        VARCHAR(32)  NOT NULL DEFAULT '2 ранг',
    MODIFY `rank3`        VARCHAR(32)  NOT NULL DEFAULT '3 ранг',
    MODIFY `rank4`        VARCHAR(32)  NOT NULL DEFAULT '4 ранг',
    MODIFY `rank5`        VARCHAR(32)  NOT NULL DEFAULT '5 ранг',
    MODIFY `rank6`        VARCHAR(32)  NOT NULL DEFAULT '6 ранг',
    MODIFY `rank7`        VARCHAR(32)  NOT NULL DEFAULT '7 ранг',
    MODIFY `rank8`        VARCHAR(32)  NOT NULL DEFAULT '8 ранг',
    MODIFY `rank9`        VARCHAR(32)  NOT NULL DEFAULT '9 ранг',
    MODIFY `rank10`       VARCHAR(32)  NOT NULL DEFAULT 'Лидер',
    MODIFY `money`        INT(11)      NOT NULL DEFAULT 0,
    MODIFY `drugs`        INT(11)      NOT NULL DEFAULT 0,
    MODIFY `tree`         INT(11)      NOT NULL DEFAULT 0,
    MODIFY `metal`        INT(11)      NOT NULL DEFAULT 0,
    MODIFY `ammo`         INT(11)      NOT NULL DEFAULT 0,
    MODIFY `house_id`     INT(11)      NOT NULL DEFAULT -1,
    MODIFY `pos_x`        FLOAT        NOT NULL DEFAULT 0,
    MODIFY `pos_y`        FLOAT        NOT NULL DEFAULT 0,
    MODIFY `pos_z`        FLOAT        NOT NULL DEFAULT 0,
    MODIFY `pos_fa`       FLOAT        NOT NULL DEFAULT 0,
    MODIFY `inter`        INT(11)      NOT NULL DEFAULT 0,
    MODIFY `world`        INT(11)      NOT NULL DEFAULT 0,
    MODIFY `ochki`        INT(11)      NOT NULL DEFAULT 0,
    MODIFY `ochki1`       INT(11)      NOT NULL DEFAULT 0,
    MODIFY `ochki2`       INT(11)      NOT NULL DEFAULT 0,
    MODIFY `ochki3`       INT(11)      NOT NULL DEFAULT 0,
    MODIFY `ochki4`       INT(11)      NOT NULL DEFAULT 0,
    MODIFY `family_cars`  INT(11)      NOT NULL DEFAULT 0,
    MODIFY `ad_text`      VARCHAR(128) NOT NULL DEFAULT '',
    MODIFY `r_TakeMoney`  INT(11)      NOT NULL DEFAULT 10,
    MODIFY `r_TakeDrugs`  INT(11)      NOT NULL DEFAULT 10,
    MODIFY `r_TakeMetall` INT(11)      NOT NULL DEFAULT 10,
    MODIFY `r_TakeAmmo`   INT(11)      NOT NULL DEFAULT 10,
    MODIFY `r_Inv`        INT(11)      NOT NULL DEFAULT 9,
    MODIFY `r_UnInv`      INT(11)      NOT NULL DEFAULT 9,
    MODIFY `r_Mute`       INT(11)      NOT NULL DEFAULT 9,
    MODIFY `r_UnMute`     INT(11)      NOT NULL DEFAULT 9,
    MODIFY `r_Warn`       INT(11)      NOT NULL DEFAULT 9,
    MODIFY `r_UnWarn`     INT(11)      NOT NULL DEFAULT 9,
    MODIFY `r_GiveRang`   INT(11)      NOT NULL DEFAULT 10;

-- 3. Если ALTER выше упал с ошибкой 1054 (Unknown column) — значит колонки
--    физически нет. Добавь её и повтори. Пример:
--
--    ALTER TABLE `family` ADD COLUMN `ad_text` VARCHAR(128) NOT NULL DEFAULT '';
--    ALTER TABLE `family` ADD COLUMN `family_cars` INT(11) NOT NULL DEFAULT 0;

-- 4. Если таблицы `family` нет вообще (ошибка 1146) — создай с нуля:
/*
CREATE TABLE IF NOT EXISTS `family` (
    `id`           INT(11)      NOT NULL AUTO_INCREMENT,
    `name`         VARCHAR(64)  NOT NULL DEFAULT '',
    `u_id`         INT(11)      NOT NULL DEFAULT 0,
    `time`         INT(11)      NOT NULL DEFAULT 0,
    `color`        INT(11)      NOT NULL DEFAULT 0,
    `level`        INT(11)      NOT NULL DEFAULT 1,
    `exp`          INT(11)      NOT NULL DEFAULT 0,
    `rank1`        VARCHAR(32)  NOT NULL DEFAULT '1 ранг',
    `rank2`        VARCHAR(32)  NOT NULL DEFAULT '2 ранг',
    `rank3`        VARCHAR(32)  NOT NULL DEFAULT '3 ранг',
    `rank4`        VARCHAR(32)  NOT NULL DEFAULT '4 ранг',
    `rank5`        VARCHAR(32)  NOT NULL DEFAULT '5 ранг',
    `rank6`        VARCHAR(32)  NOT NULL DEFAULT '6 ранг',
    `rank7`        VARCHAR(32)  NOT NULL DEFAULT '7 ранг',
    `rank8`        VARCHAR(32)  NOT NULL DEFAULT '8 ранг',
    `rank9`        VARCHAR(32)  NOT NULL DEFAULT '9 ранг',
    `rank10`       VARCHAR(32)  NOT NULL DEFAULT 'Лидер',
    `money`        INT(11)      NOT NULL DEFAULT 0,
    `drugs`        INT(11)      NOT NULL DEFAULT 0,
    `tree`         INT(11)      NOT NULL DEFAULT 0,
    `metal`        INT(11)      NOT NULL DEFAULT 0,
    `ammo`         INT(11)      NOT NULL DEFAULT 0,
    `house_id`     INT(11)      NOT NULL DEFAULT -1,
    `pos_x`        FLOAT        NOT NULL DEFAULT 0,
    `pos_y`        FLOAT        NOT NULL DEFAULT 0,
    `pos_z`        FLOAT        NOT NULL DEFAULT 0,
    `pos_fa`       FLOAT        NOT NULL DEFAULT 0,
    `inter`        INT(11)      NOT NULL DEFAULT 0,
    `world`        INT(11)      NOT NULL DEFAULT 0,
    `ochki`        INT(11)      NOT NULL DEFAULT 0,
    `ochki1`       INT(11)      NOT NULL DEFAULT 0,
    `ochki2`       INT(11)      NOT NULL DEFAULT 0,
    `ochki3`       INT(11)      NOT NULL DEFAULT 0,
    `ochki4`       INT(11)      NOT NULL DEFAULT 0,
    `family_cars`  INT(11)      NOT NULL DEFAULT 0,
    `ad_text`      VARCHAR(128) NOT NULL DEFAULT '',
    `r_TakeMoney`  INT(11)      NOT NULL DEFAULT 10,
    `r_TakeDrugs`  INT(11)      NOT NULL DEFAULT 10,
    `r_TakeMetall` INT(11)      NOT NULL DEFAULT 10,
    `r_TakeAmmo`   INT(11)      NOT NULL DEFAULT 10,
    `r_Inv`        INT(11)      NOT NULL DEFAULT 9,
    `r_UnInv`      INT(11)      NOT NULL DEFAULT 9,
    `r_Mute`       INT(11)      NOT NULL DEFAULT 9,
    `r_UnMute`     INT(11)      NOT NULL DEFAULT 9,
    `r_Warn`       INT(11)      NOT NULL DEFAULT 9,
    `r_UnWarn`     INT(11)      NOT NULL DEFAULT 9,
    `r_GiveRang`   INT(11)      NOT NULL DEFAULT 10,
    PRIMARY KEY (`id`),
    UNIQUE KEY `name` (`name`)
) ENGINE=InnoDB DEFAULT CHARSET=cp1251;
*/
