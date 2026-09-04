// family_gui.pwn
// Активация встроенного (но ранее не подключённого) меню семьи.
// Главное меню и все действия — классические диалоги SA:MP (DIALOG_FAMILY_*),
// т.к. вся backend-логика (g_family/GetFamilyData, ранги, склад, захваты)
// уже реализована именно под диалоги в black.pwn.
//
// Экран guiid 45 (GUIFamilySystem / FamilyGuiHandlePacket) оставлен как
// пустой JSON-роутер на будущее и в обычном потоке не используется.

stock FamilyGui_Show(playerid)
{
    if(!GetPlayerData(playerid, P_FAMILY))
        return SendClientMessage(playerid, 0xCECECEFF, "Вы не состоите в семье");

    new fam_id = GetPlayerData(playerid, P_FAMILY);

    new list_text[512];
    format(list_text, sizeof list_text,
        "{FFFF00}[1] {FFFFFF}Объявление\n\
        {FFFF00}[2] {FFFFFF}Информация о семье\n\
        {FFFF00}[3] {FFFFFF}Список команд\n\
        {FFFF00}[4] {FFFFFF}Настройки\n\
        {FFFF00}[5] {FFFFFF}Покинуть семью\n\
        {FFFF00}[6] {FFFFFF}Участники"
    );

    Dialog
    (
        playerid, DIALOG_FAMILY_MENU, DIALOG_STYLE_LIST,
        GetFamilyData(fam_id, F_NAME),
        list_text,
        "Выбрать", "Закрыть"
    );
    return 1;
}

// Реальный экран объявления (вместо статичной заглушки "Обьявлений не найдено.")
stock FamilyGui_ShowAd(playerid)
{
    new fam_id = GetPlayerData(playerid, P_FAMILY);
    new msg[160];

    if(!strlen(GetFamilyData(fam_id, F_AD_TEXT)))
        strcat(msg, "{FFFFFF}Объявлений нет.");
    else
        format(msg, sizeof msg, "{FFFFFF}%s", GetFamilyData(fam_id, F_AD_TEXT));

    Dialog(playerid, INVALID_DIALOG_ID, DIALOG_STYLE_MSGBOX, "Объявление семьи", msg, "Закрыть", "");
    return 1;
}

stock FamilyGui_ShowAdInput(playerid)
{
    if(GetPlayerData(playerid, P_FAMILY_RANK) != 10)
        return SendClientMessage(playerid, 0xCECECEFF, "У Вас нет доступа");

    Dialog
    (
        playerid, DIALOG_FAMILY_AD_INPUT, DIALOG_STYLE_INPUT,
        "Объявление семьи",
        "{FFFFFF}Введите текст объявления (до 127 символов):",
        "Далее", "Отмена"
    );
    return 1;
}

// Список игроков онлайн (без семьи) для приглашения — заменяет ручной ввод id
stock FamilyGui_ShowInvitePicker(playerid)
{
    new fam_id = GetPlayerData(playerid, P_FAMILY);
    new rank_needed = GetFamilyData(fam_id, F_RANG_INV);

    if(GetPlayerData(playerid, P_FAMILY_RANK) < rank_needed)
        return SendClientMessage(playerid, 0xCECECEFF, "У вас недостаточный ранг в семье, чтобы приглашать людей");

    new list_text[512];
    new count;

    for(new i; i < MAX_PLAYERS; i++)
    {
        if(!IsPlayerConnected(i)) continue;
        if(!IsPlayerLogged(i)) continue;
        if(i == playerid) continue;
        if(GetPlayerData(i, P_FAMILY)) continue;
        if(!IsPlayerInRangeOfPlayer(playerid, i, 10.0)) continue;

        format(list_text, sizeof list_text, "%s{FFFFFF}%s [%d]\n", list_text, GetPlayerNameEx(i), i);
        count++;

        SetPVarInt(playerid, sprintf_pvar_key("famgui_invite", count - 1), i);

        if(count >= 20) break;
    }

    if(!count)
        return SendClientMessage(playerid, 0xCECECEFF, "Рядом нет игроков без семьи для приглашения");

    SetPVarInt(playerid, "famgui_invite_count", count);

    Dialog(playerid, DIALOG_FAMILY_INVITE, DIALOG_STYLE_LIST, "Пригласить в семью", list_text, "Пригласить", "Отмена");
    return 1;
}

stock sprintf_pvar_key(const prefix[], n)
{
    new key[32];
    format(key, sizeof key, "%s_%d", prefix, n);
    return key;
}

// Список участников семьи
stock FamilyGui_ShowMembers(playerid)
{
    new query[128];
    mysql_format(mysql, query, sizeof query, "SELECT name, score, family_rank FROM accounts WHERE family = %d ORDER BY family_rank DESC", GetPlayerData(playerid, P_FAMILY));
    mysql_tquery(mysql, query, "ShowFamilyAllPlayers", "i", playerid);
    return 1;
}

stock FamilyGui_HandlePacket(playerid, Node:request)
{
    #pragma unused playerid, request
    return 0;
}

stock FamilyGui_OnDialogResponse(playerid, dialogid, response, listitem, inputtext[])
{
    if(dialogid == DIALOG_FAMILY_MENU)
    {
        if(!response) return 1;

        switch(listitem)
        {
            case 0: FamilyGui_ShowAd(playerid);
            case 1: ShowFamilyInfo(playerid);
            case 2: ShowFamilyHelpCommands(playerid);
            case 3:
            {
                if(GetPlayerData(playerid, P_FAMILY_RANK) != 10)
                    return SendClientMessage(playerid, 0xCECECEFF, "У Вас нет доступа");

                Dialog
                (
                    playerid, DIALOG_FAMILY_SETTINGS, DIALOG_STYLE_LIST,
                    "Настройки",
                    "\
                    [1] Установить место появления\n\
                    [2] Управление рангами\n\
                    [3] Сменить название семьи (80 руб.)\n\
                    [4] Сменить цвет семьи (20 руб.)\n\
                    [5] Настройка доступа рангов\n\
                    [6] Управление транспортом\n\
                    [7] Объявление",
                    "Далее", ""
                );
            }
            case 4: callcmd::fleave(playerid, "");
            case 5: FamilyGui_ShowInvitePicker(playerid);
        }
        return 1;
    }

    if(dialogid == DIALOG_FAMILY_SETTINGS)
    {
        if(response && listitem == 6)
        {
            FamilyGui_ShowAdInput(playerid);
            return 1;
        }
        return 0; // остальные пункты уже обрабатываются в black.pwn
    }

    if(dialogid == DIALOG_FAMILY_AD_INPUT)
    {
        if(!response) return 1;

        if(!(1 <= strlen(inputtext) <= 127))
            return SendClientMessage(playerid, 0xCECECEFF, "Текст объявления от 1 до 127 символов");

        new fam_id = GetPlayerData(playerid, P_FAMILY);

        format(g_family[fam_id][F_AD_TEXT], 128, "%s", inputtext);

        new query[256];
        mysql_format(mysql, query, sizeof query, "UPDATE family SET ad_text='%e' WHERE id=%d", inputtext, GetFamilyData(fam_id, F_SQL_ID));
        mysql_query(mysql, query, false);

        SendClientMessage(playerid, 0x1E90FFFF, "Объявление обновлено");
        return 1;
    }

    if(dialogid == DIALOG_FAMILY_INVITE)
    {
        if(!response) return 1;

        new target = GetPVarInt(playerid, sprintf_pvar_key("famgui_invite", listitem));
        DeletePVar(playerid, "famgui_invite_count");

        if(!IsPlayerConnected(target) || !IsPlayerLogged(target))
            return SendClientMessage(playerid, 0xCECECEFF, "Игрок больше не в сети");

        new params[16];
        format(params, sizeof params, "%d", target);
        callcmd::finvite(playerid, params);
        return 1;
    }

    if(dialogid == DIALOG_FAMILY_CREATE)
    {
        if(!response) return 1;
        FamilyCreate(playerid, inputtext);
        return 1;
    }

    return 0;
}

#define FAMILY_CREATE_PRICE 3000000

stock ShowFamilyCreateDialog(playerid)
{
    Dialog
    (
        playerid, DIALOG_FAMILY_CREATE, DIALOG_STYLE_INPUT,
        "Создание семьи",
        "{FFFFFF}Стоимость создания семьи: " c_m "3 000 000$\n\n{FFFFFF}Введите название семьи (от 6 до 32 символов):",
        "Создать", "Отмена"
    );
    return 1;
}

stock FamilyGui_Create(playerid, const source_name[])
{
    if(GetPlayerIdFamily(playerid) != -1)
        return SendClientMessage(playerid, 0xCECECEFF, "Вы уже состоите в семье");

    if(GetPlayerMoneyEx(playerid) < FAMILY_CREATE_PRICE)
        return SendClientMessage(playerid, 0xCECECEFF, "Недостаточно денег для создания семьи (нужно 3 000 000$)");

    // g_family объявлен как g_family[200], а рабочие индексы идут с 1
    // (fam_id = g_family_loaded + 1), т.е. максимум допустим 199.
    // Старая проверка >= 200 пропускала 199-ю семью и та писалась в g_family[200]
    // — выход за границу массива.
    if(g_family_loaded >= sizeof(g_family) - 1)
        return SendClientMessage(playerid, 0xCECECEFF, "На данный момент создать семью нельзя (достигнут лимит семей)");

    // Название приходит из диалога в UTF-8, а БД/геймод работают в cp1251
    // (mysql_set_charset("cp1251")). Без конвертации в базу уходили кракозябры.
    new fam_name[64];
    format(fam_name, sizeof fam_name, "%s", source_name);
    utf8_to_cp1251(fam_name);

    // Длину проверяем ПОСЛЕ конвертации: в UTF-8 кириллица занимает 2 байта,
    // поэтому "Семья" (5 букв) давала strlen 10 и проходила проверку, а
    // название из 17 русских букв (34 байта) — наоборот, отсекалось.
    new fam_len = strlen(fam_name);
    if(!(6 <= fam_len <= 32))
        return SendClientMessage(playerid, 0xCECECEFF, "Название семьи должно быть от 6 до 32 символов");

    // Буфер: полный INSERT со всеми колонками занимает ~900 символов
    // (старый query[256] не вмещал даже прежний укороченный вариант на 221
    // символ — mysql_format молча резал запрос по границе буфера).
    new query[1536];

    // Проверка занятости названия — раньше её не было, и INSERT падал
    // на UNIQUE-индексе поля `name` с ошибкой 1062 вместо внятного сообщения.
    mysql_format(mysql, query, sizeof query, "SELECT id FROM family WHERE name='%e' LIMIT 1", fam_name);
    new Cache:dup_cache = mysql_query(mysql, query, true);
    if(mysql_errno())
    {
        cache_delete(dup_cache);
        printf("[FAMILY CREATE] mysql_errno #0 (dup check): %d", mysql_errno());
        return SendClientMessage(playerid, 0xCECECEFF, "Ошибка создания семьи, попробуйте позже");
    }
    if(cache_num_rows())
    {
        cache_delete(dup_cache);
        return SendClientMessage(playerid, 0xCECECEFF, "Семья с таким названием уже существует");
    }
    cache_delete(dup_cache);

    // ГЛАВНАЯ ПРИЧИНА ОШИБКИ: старый INSERT заполнял только 14 колонок из 47.
    // Остальные 33 (rank1..rank10, pos_x/y/z/fa, inter, world, money, drugs,
    // tree, metal, ammo, house_id, color, level, exp, ochki..ochki4,
    // family_cars, ad_text) LoadFamily() читает, но при вставке они не
    // задавались. Таблица `family` геймодом не создаётся (её нет ни в одном
    // CREATE TABLE) — она пришла из дампа, где эти поля объявлены NOT NULL
    // без DEFAULT. MySQL в STRICT_TRANS_TABLES (режим по умолчанию с 5.7)
    // отклоняет такой INSERT с ошибкой 1364 "Field doesn't have a default
    // value". Поэтому запрос падал всегда, независимо от названия семьи.
    // Теперь перечисляем все колонки явно со здравыми значениями.
    mysql_format(mysql, query, sizeof query,
        "INSERT INTO family (name, u_id, time, color, level, exp, \
        rank1, rank2, rank3, rank4, rank5, rank6, rank7, rank8, rank9, rank10, \
        money, drugs, tree, metal, ammo, house_id, \
        pos_x, pos_y, pos_z, pos_fa, inter, world, \
        ochki, ochki1, ochki2, ochki3, ochki4, family_cars, ad_text, \
        r_TakeMoney, r_TakeDrugs, r_TakeMetall, r_TakeAmmo, \
        r_Inv, r_UnInv, r_Mute, r_UnMute, r_Warn, r_UnWarn, r_GiveRang) \
        VALUES ('%e', %d, %d, 0, 1, 0, \
        '1 ранг', '2 ранг', '3 ранг', '4 ранг', '5 ранг', \
        '6 ранг', '7 ранг', '8 ранг', '9 ранг', 'Лидер', \
        0, 0, 0, 0, 0, -1, \
        0.0, 0.0, 0.0, 0.0, 0, 0, \
        0, 0, 0, 0, 0, 0, '', \
        10, 10, 10, 10, 9, 9, 9, 9, 9, 9, 10)",
        fam_name, GetPlayerAccountID(playerid), gettime());
    mysql_query(mysql, query, false);

    if(mysql_errno())
    {
        // Печатаем и код, и сам запрос — по коду сразу видно причину:
        // 1054 = нет такой колонки, 1146 = нет таблицы `family`,
        // 1364 = колонка без DEFAULT, 1062 = дубликат, 1064 = битый SQL.
        new err = mysql_errno();
        printf("[FAMILY CREATE] INSERT failed, mysql_errno = %d", err);
        printf("[FAMILY CREATE] query was: %s", query);

        new err_msg[144];
        format(err_msg, sizeof err_msg, "Ошибка создания семьи (код MySQL: %d). Сообщите администрации.", err);
        return SendClientMessage(playerid, 0xCECECEFF, err_msg);
    }

    mysql_format(mysql, query, sizeof query, "SELECT * FROM family WHERE u_id = %d ORDER BY id DESC LIMIT 1", GetPlayerAccountID(playerid));
    new Cache:cache = mysql_query(mysql, query);

    if(mysql_errno() || !cache_num_rows())
    {
        cache_delete(cache);
        printf("[FAMILY CREATE] mysql_errno #2: %d", mysql_errno());
        return SendClientMessage(playerid, 0xCECECEFF, "Ошибка создания семьи, попробуйте позже");
    }

    new fam_id = g_family_loaded + 1;

    SetFamilyData(fam_id, F_SQL_ID,    cache_get_field_content_int(0, "id"));
    cache_get_field_content(0, "name", g_family[fam_id][F_NAME], mysql, 64);
    SetFamilyData(fam_id, F_USER_ID,   cache_get_field_content_int(0, "u_id"));
    SetFamilyData(fam_id, F_TIME,      cache_get_field_content_int(0, "time"));
    SetFamilyData(fam_id, F_COLOR,     cache_get_field_content_int(0, "color"));
    SetFamilyData(fam_id, F_HOUSE_ID,  -1);
    SetFamilyData(fam_id, F_LEVEL,     1);   // раньше не выставлялись — семья
    SetFamilyData(fam_id, F_EXP,       0);   // до перезахода была 0 уровня
    SetFamilyData(fam_id, F_TAKE_MONEY, cache_get_field_content_int(0, "r_TakeMoney"));
    SetFamilyData(fam_id, F_TAKE_DRUGS, cache_get_field_content_int(0, "r_TakeDrugs"));
    SetFamilyData(fam_id, F_TAKE_METALL,cache_get_field_content_int(0, "r_TakeMetall"));
    SetFamilyData(fam_id, F_TAKE_AMMO,  cache_get_field_content_int(0, "r_TakeAmmo"));
    SetFamilyData(fam_id, F_RANG_INV,   cache_get_field_content_int(0, "r_Inv"));
    SetFamilyData(fam_id, F_RANG_UNINV, cache_get_field_content_int(0, "r_UnInv"));
    SetFamilyData(fam_id, F_RANG_MUTE,  cache_get_field_content_int(0, "r_Mute"));
    SetFamilyData(fam_id, F_RANG_UNMUTE,cache_get_field_content_int(0, "r_UnMute"));
    SetFamilyData(fam_id, F_RANG_WARN,  cache_get_field_content_int(0, "r_Warn"));
    SetFamilyData(fam_id, F_RANG_UNWARN,cache_get_field_content_int(0, "r_UnWarn"));
    SetFamilyData(fam_id, F_RANG_GIVER, cache_get_field_content_int(0, "r_GiveRang"));
    format(g_family[fam_id][F_RANK1], 32, "1 ранг");
    format(g_family[fam_id][F_RANK2], 32, "2 ранг");
    format(g_family[fam_id][F_RANK3], 32, "3 ранг");
    format(g_family[fam_id][F_RANK4], 32, "4 ранг");
    format(g_family[fam_id][F_RANK5], 32, "5 ранг");
    format(g_family[fam_id][F_RANK6], 32, "6 ранг");
    format(g_family[fam_id][F_RANK7], 32, "7 ранг");
    format(g_family[fam_id][F_RANK8], 32, "8 ранг");
    format(g_family[fam_id][F_RANK9], 32, "9 ранг");
    format(g_family[fam_id][F_RANK10], 32, "Лидер");
    g_family[fam_id][F_AD_TEXT][0] = 0;

    cache_delete(cache);
    g_family_loaded++;

    // GivePlayerMoney трогает только клиентский счётчик — серверный баланс
    // (P_MONEY, по нему же считает проверка выше) оставался прежним, деньги
    // возвращались после релога. Списываем через штатную функцию геймода.
    GivePlayerMoneyEx(playerid, -FAMILY_CREATE_PRICE, "Создание семьи");
    SetPlayerData(playerid, P_FAMILY, fam_id);
    SetPlayerData(playerid, P_FAMILY_RANK, 10);

    mysql_format(mysql, query, sizeof query, "UPDATE accounts SET family=%d, family_rank=10 WHERE id=%d", fam_id, GetPlayerAccountID(playerid));
    mysql_query(mysql, query, false);

    new fmt_text[128];
    format(fmt_text, sizeof fmt_text, "Семья «%s» успешно создана! Вы её лидер", source_name);
    SendClientMessage(playerid, 0x1E90FFFF, fmt_text);
    return 1;
}
