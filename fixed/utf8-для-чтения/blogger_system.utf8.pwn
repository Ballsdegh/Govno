/*
    ============================================================
     СИСТЕМА ДЛЯ БЛОГЕРОВ (fake-nick / fake-mileage)
    ============================================================
    Команда:  /blogger [id]   (алиас /streamersys)
    Доступ:   GetPlayerAdminEx(playerid) >= 1  (см. BLOGGER_ADMIN_LVL ниже)

    Что делает:
      1. Меняет игроку реальный игровой ник (SetPlayerName) — влияет
         на никнейм над головой, в чате, в списке игроков (Tab).
      2. Ставит любой пробег текущему автомобилю игрока через уже
         существующую в геймоде функцию SetVehicleSpeedometerInfo()
         (обновляет спидометр у всех, кто сидит в машине).
      3. Всё это сохраняется в БД (таблица blogger_profiles) и
         автоматически восстанавливается при следующем входе игрока
         — до тех пор, пока админ не нажмёт "Сбросить оформление".

    ЗАВИСИМОСТИ (уже есть в твоём геймоде): a_mysql, sscanf2, foreach.

    ============================================================
     ИНТЕГРАЦИЯ (3 маленькие правки в gamemodes/black-russia.pwn)
    ============================================================

    1) Подключение файла — рядом с другими #include "../include/system/...":

           #include "../include/system/blogger_system.pwn"

       (можно просто добавить строку сразу после
        #include "../include/system/admin_nick_color.pwn")

    2) Таблица в БД — добавь в OnGameModeInit(), рядом с
       CREATE TABLE IF NOT EXISTS `marketplace_lots` (...):

           mysql_tquery(mysql, "CREATE TABLE IF NOT EXISTS `blogger_profiles` (\
               `account_id` INT(11) NOT NULL,\
               `enabled` TINYINT(1) NOT NULL DEFAULT 0,\
               `fake_nick` VARCHAR(24) NOT NULL DEFAULT '',\
               PRIMARY KEY (`account_id`)\
           ) ENGINE=InnoDB DEFAULT CHARSET=cp1251");

    3) Подгрузка при входе — в public: LoadPlayerData(playerid),
       сразу после строки:

           LoadAccessory(playerid);

       добавь:

           Blogger_OnPlayerLogin(playerid);

    4) Очистка при выходе — в public OnPlayerDisconnect(playerid, reason),
       рядом со строкой:

           CoordsHud_Destroy(playerid); // include/system/coords_hud.pwn

       добавь:

           Blogger_OnPlayerDisconnect(playerid, reason);

    5) Диалоги — в public OnDialogResponse(...), сразу после строки:

           if (FamilyGui_OnDialogResponse(playerid, dialogid, response, listitem, inputtext)) return 1;

       добавь:

           if (Blogger_OnDialogResponse(playerid, dialogid, response, listitem, inputtext)) return 1;

    Больше никаких правок в основном файле не требуется — весь остальной
    код полностью в этом файле, по той же схеме, что и остальные модули
    в include/system/.
    ============================================================
*/

#define BLOGGER_ADMIN_LVL       1       // минимальный уровень админки для /blogger

#define DLG_BLG_MAIN            9050
#define DLG_BLG_NICK            9051
#define DLG_BLG_MILEAGE         9053
#define DLG_BLG_RESET_CONFIRM   9054

enum E_BLOGGER_DATA
{
    bool:bd_Enabled
};
new BloggerData[MAX_PLAYERS][E_BLOGGER_DATA];

// Подмена ID убрана из системы блогера: игрокам всегда показывается
// настоящий playerid. Функция оставлена, потому что её вызывает основной
// геймод в десятках мест форматирования чата.
stock Blogger_GetDisplayID(playerid)
{
    return playerid;
}

new BloggerTemp[MAX_PLAYERS];   // playerid админа -> playerid цели, на которую открыто меню
new BloggerMenuOffset[MAX_PLAYERS]; // сколько первых строк ShowBloggerMenu - инфо-шапка

// считает количество строк (\n) в строке - нужно, чтобы точно знать, сколько
// первых пунктов DIALOG_STYLE_LIST занимает инфо-шапка, а не пункты меню
stock CountLines(const text[])
{
    new count = 0;
    for(new i = 0; text[i] != 0; i++)
    {
        if(text[i] == '\n') count++;
    }
    return count;
}

// ================= ВСПОМОГАТЕЛЬНОЕ =================

stock bool:Blogger_IsValidNick(const nick[])
{
    new len = strlen(nick);
    if(len < 3 || len > 20) return false;

    for(new i; i < len; i++)
    {
        new c = nick[i];
        if(!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'))
            return false;
    }
    return true;
}

// сохраняет текущее состояние (ник берём из GetPlayerNameEx, т.к. он уже подменён SetPlayerName)
stock Blogger_Persist(playerid)
{
    new query[256];
    mysql_format(mysql, query, sizeof query,
        "INSERT INTO blogger_profiles (account_id, enabled, fake_nick) VALUES (%d, 1, '%e') \
         ON DUPLICATE KEY UPDATE enabled=1, fake_nick='%e'",
        GetPlayerAccountID(playerid), GetPlayerNameEx(playerid),
        GetPlayerNameEx(playerid));
    mysql_tquery(mysql, query);
    return 1;
}

// ================= ЗАГРУЗКА ПРИ ВХОДЕ =================

Blogger_OnPlayerLogin(playerid)
{
    BloggerData[playerid][bd_Enabled] = false;

    new query[128];
    mysql_format(mysql, query, sizeof query,
        "SELECT enabled, fake_nick FROM blogger_profiles WHERE account_id=%d LIMIT 1",
        GetPlayerAccountID(playerid));
    mysql_tquery(mysql, query, "OnBloggerProfileLoaded", "i", playerid);
    return 1;
}

forward OnBloggerProfileLoaded(playerid);
public OnBloggerProfileLoaded(playerid)
{
    if(!IsPlayerConnected(playerid)) return 1;
    if(cache_num_rows() > 0 && cache_get_field_content_int(0, "enabled") == 1)
    {
        new fake_nick[24], namebuf[21];
        cache_get_field_content(0, "fake_nick", fake_nick);

        if(strlen(fake_nick) > 0 && SetPlayerName(playerid, fake_nick) == 1)
        {
            format(namebuf, sizeof namebuf, "%s", fake_nick);
            SetPlayerData(playerid, P_NAME, namebuf);
            BloggerData[playerid][bd_Enabled] = true;
        }
    }
    return 1;
}

Blogger_OnPlayerDisconnect(playerid, reason)
{
    #pragma unused reason
    BloggerData[playerid][bd_Enabled] = false;
    return 1;
}

// ================= КОМАНДА =================

CMD:blogger(playerid, params[])
{
    if(GetPlayerAdminEx(playerid) < BLOGGER_ADMIN_LVL)
        return SendClientMessage(playerid, 0xCECECEFF, "У Вас нет доступа к этой команде.");

    new target;
    if(sscanf(params, "u", target))
        target = playerid;

    if(!IsPlayerConnected(target) || !IsPlayerLogged(target))
        return SendClientMessage(playerid, 0xCECECEFF, "Игрок не в сети.");

    BloggerTemp[playerid] = target;
    ShowBloggerMenu(playerid);
    return 1;
}
alias:blogger("streamersys")

// ================= МЕНЮ =================

ShowBloggerMenu(playerid)
{
    new target = BloggerTemp[playerid], str[400];

    new status_str[24];
    if(BloggerData[target][bd_Enabled])
        format(status_str, sizeof status_str, "{33FF33}включено");
    else
        format(status_str, sizeof status_str, "{FF3333}выключено");

    // Инфо-шапка снова внутри диалога. Число её строк СЧИТАЕТСЯ автоматически
    // (CountLines) и хранится в BloggerMenuOffset - обработчик диалога вычитает
    // его из listitem, поэтому индексы пунктов меню больше никогда не съедут,
    // даже если текст шапки потом изменится.
    new header[200];
    format(header, sizeof header,
        "{ADD8E6}Игрок:{FFFFFF} %s (ID: %d)\n{ADD8E6}Оформление блогера:%s\n",
        GetPlayerNameEx(target), target, status_str);
    BloggerMenuOffset[playerid] = CountLines(header);

    format(str, sizeof str,
        "%s{FFFFFF}Изменить ник\n"\
        "{FFFFFF}Установить пробег текущего авто\n"\
        "{FF9999}Сбросить оформление (вернуть настоящее)", header);

    ShowPlayerDialog(playerid, DLG_BLG_MAIN, DIALOG_STYLE_LIST,
        "Система для блогеров", str, "Выбрать", "Закрыть");
}

// ================= ОБРАБОТКА ДИАЛОГОВ =================

Blogger_OnDialogResponse(playerid, dialogid, response, listitem, inputtext[])
{
    switch(dialogid)
    {
        case DLG_BLG_MAIN:
        {
            if(!response) return 1;
            new target = BloggerTemp[playerid];
            new realitem = listitem - BloggerMenuOffset[playerid];

            switch(realitem)
            {
                case 0:
                {
                    ShowPlayerDialog(playerid, DLG_BLG_NICK, DIALOG_STYLE_INPUT,
                        "Новый ник", "Введите новый ник игроку (3-20 симв., латиница/цифры/_):\nПример: Max_Payne", "Далее", "Назад");
                }

                case 1:
                {
                    if(!IsPlayerConnected(target) || GetPlayerVehicleID(target) == 0)
                    {
                        SendClientMessage(playerid, 0xFF3333AA, "Игрок должен находиться в автомобиле.");
                        return ShowBloggerMenu(playerid);
                    }
                    ShowPlayerDialog(playerid, DLG_BLG_MILEAGE, DIALOG_STYLE_INPUT,
                        "Пробег", "Введите новый пробег авто (км), например 158420.5:", "Установить", "Назад");
                }

                case 2:
                {
                    ShowPlayerDialog(playerid, DLG_BLG_RESET_CONFIRM, DIALOG_STYLE_MSGBOX,
                        "Подтверждение", "Вернуть игроку настоящий ник?", "Сбросить", "Отмена");
                }
            }
            return 1;
        }

        case DLG_BLG_NICK:
        {
            if(!response) return ShowBloggerMenu(playerid);
            new target = BloggerTemp[playerid];

            if(!Blogger_IsValidNick(inputtext))
            {
                SendClientMessage(playerid, 0xFF3333AA, "Неверный формат. 3-20 символов: латиница, цифры, _");
                return ShowPlayerDialog(playerid, DLG_BLG_NICK, DIALOG_STYLE_INPUT,
                    "Новый ник", "Введите новый ник игроку (3-20 симв., латиница/цифры/_):\nПример: Max_Payne", "Далее", "Назад");
            }

            if(!IsPlayerConnected(target))
            {
                SendClientMessage(playerid, 0xFF3333AA, "Игрок вышел из игры.");
                return ShowBloggerMenu(playerid);
            }

            if(SetPlayerName(target, inputtext) != 1)
            {
                SendClientMessage(playerid, 0xFF3333AA, "Не удалось изменить ник (возможно, уже занят).");
                return ShowBloggerMenu(playerid);
            }

            new namebuf[21];
            format(namebuf, sizeof namebuf, "%s", inputtext);
            SetPlayerData(target, P_NAME, namebuf);
            BloggerData[target][bd_Enabled] = true;
            Blogger_Persist(target);

            SendClientMessage(playerid, 0x33FF33AA, "Ник игрока изменён и сохранён.");
            SendClientMessage(target, 0x33FF33AA, "Ваш игровой ник был изменён администратором.");
            return ShowBloggerMenu(playerid);
        }

        case DLG_BLG_MILEAGE:
        {
            if(!response) return ShowBloggerMenu(playerid);
            new target = BloggerTemp[playerid];
            new Float:mileage_value;

            if(sscanf(inputtext, "f", mileage_value) || mileage_value < 0.0 || mileage_value > 9999999.0)
            {
                SendClientMessage(playerid, 0xFF3333AA, "Введите корректное число (0 - 9999999).");
                return ShowPlayerDialog(playerid, DLG_BLG_MILEAGE, DIALOG_STYLE_INPUT,
                    "Пробег", "Введите новый пробег авто (км), например 158420.5:", "Установить", "Назад");
            }

            if(!IsPlayerConnected(target) || GetPlayerVehicleID(target) == 0)
            {
                SendClientMessage(playerid, 0xFF3333AA, "Игрок больше не в автомобиле.");
                return ShowBloggerMenu(playerid);
            }

            new vehicleid = GetPlayerVehicleID(target);
            SetVehicleSpeedometerInfo(vehicleid, GetVehicleData(vehicleid, V_FUEL), mileage_value);

            if(vInfo[vehicleid][vSQLID] > 0)
            {
                new query[128];
                mysql_format(mysql, query, sizeof query,
                    "UPDATE ownable_cars SET mileage=%f WHERE id=%d LIMIT 1",
                    mileage_value, vInfo[vehicleid][vSQLID]);
                mysql_tquery(mysql, query);
                SendClientMessage(playerid, 0x33FF33AA, "Пробег установлен и сохранён в базе (личный авто).");
            }
            else
            {
                SendClientMessage(playerid, 0x33FF33AA, "Пробег установлен визуально.");
                SendClientMessage(playerid, 0xCECECEFF, "Это авто не является личным/сохраняемым (нет vSQLID) — значение сбросится при переспавне машины.");
            }
            return ShowBloggerMenu(playerid);
        }

        case DLG_BLG_RESET_CONFIRM:
        {
            new target = BloggerTemp[playerid];
            if(!response) return ShowBloggerMenu(playerid);

            if(!IsPlayerConnected(target))
            {
                SendClientMessage(playerid, 0xFF3333AA, "Игрок вышел из игры.");
                return 1;
            }

            new query[128];
            mysql_format(mysql, query, sizeof query,
                "UPDATE blogger_profiles SET enabled=0 WHERE account_id=%d",
                GetPlayerAccountID(target));
            mysql_tquery(mysql, query);

            mysql_format(mysql, query, sizeof query,
                "SELECT name FROM accounts WHERE id=%d LIMIT 1",
                GetPlayerAccountID(target));
            mysql_tquery(mysql, query, "OnBloggerResetName", "i", target);

            BloggerData[target][bd_Enabled] = false;

            SendClientMessage(playerid, 0x33FF33AA, "Оформление сброшено.");
            return 1;
        }
    }
    return 0;
}

forward OnBloggerResetName(playerid);
public OnBloggerResetName(playerid)
{
    if(!IsPlayerConnected(playerid)) return 1;
    if(cache_num_rows() > 0)
    {
        new real_name[24], namebuf[21];
        cache_get_field_content(0, "name", real_name);
        format(namebuf, sizeof namebuf, "%s", real_name);
        SetPlayerName(playerid, namebuf);
        SetPlayerData(playerid, P_NAME, namebuf);
        SendClientMessage(playerid, 0x33FF33AA, "Администратор вернул ваш настоящий игровой ник.");
    }
    return 1;
}
