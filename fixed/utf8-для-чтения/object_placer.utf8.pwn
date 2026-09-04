/*
    ============================================================
     СИСТЕМА УСТАНОВКИ ОБЪЕКТОВ (NPC / OBJECT / MARKER / НАДПИСЬ)
    ============================================================
    Команда: /objects (или /obj) — открывает главное меню.
    Доступ: GetPlayerAdminEx(playerid) >= OBJPLACER_ADMIN_LVL

    Все созданные объекты сохраняются в таблицу `objects_placed`
    и восстанавливаются при рестарте сервера (ObjectPlacer_LoadFromDB,
    вызывается из OnGameModeInit).

    ============================================================
     ИНТЕГРАЦИЯ (правки в gamemodes/black-russia.pwn)
    ============================================================

    1) Подключение — рядом с другими #include "../include/system/...":

           #include "../include/system/object_placer.pwn"

    2) Таблица в БД — в OnGameModeInit(), рядом с CREATE TABLE `autosalon`:

           mysql_tquery(mysql, "CREATE TABLE IF NOT EXISTS `objects_placed` (\
               `id` INT(11) NOT NULL AUTO_INCREMENT,\
               `type` TINYINT(1) NOT NULL DEFAULT 0,\
               `model_id` INT(11) NOT NULL DEFAULT 0,\
               `custom_id` INT(11) NOT NULL DEFAULT 0,\
               `name` VARCHAR(64) NOT NULL DEFAULT '',\
               `sign_text` VARCHAR(144) NOT NULL DEFAULT '',\
               `color` INT(11) NOT NULL DEFAULT 0,\
               `x` FLOAT NOT NULL DEFAULT 0,\
               `y` FLOAT NOT NULL DEFAULT 0,\
               `z` FLOAT NOT NULL DEFAULT 0,\
               `angle` FLOAT NOT NULL DEFAULT 0,\
               `created_by` VARCHAR(24) NOT NULL DEFAULT '',\
               PRIMARY KEY (`id`)\
           ) ENGINE=InnoDB DEFAULT CHARSET=cp1251");

    3) Загрузка объектов при старте сервера — в OnGameModeInit(), рядом со
       строками LoadGreenZonesFromDB(); UpdateCharity(); RepositoriesLoad();

           ObjectPlacer_LoadFromDB();

    4) Раздача иконок маркеров новым игрокам — в public OnPlayerConnect(playerid):

           ObjectPlacer_OnPlayerConnect(playerid);

    5) Диалоги — в public OnDialogResponse(...), в цепочку вызовов:

           if (ObjectPlacer_OnDialogResponse(playerid, dialogid, response, listitem, inputtext)) return 1;

    Больше правок в основном файле не требуется.
    ============================================================
*/

#define OBJPLACER_ADMIN_LVL     2       // минимальный уровень админки для /objects

// ---------------- НАСТРОЙКИ ----------------
#define MAX_PLACED_OBJECTS     500
#define MAX_FAVORITES          200
#define MAX_ICON_SLOTS         100     // ограничение SA-MP: 0-99 map icon слотов на игрока

// ---------------- ТИПЫ ОБЪЕКТОВ ----------------
enum E_OBJ_TYPE
{
    TYPE_NPC = 0,
    TYPE_OBJECT,
    TYPE_MARKER,
    TYPE_TEXT           // "Надпись" — 3D-текст в мире, с поддержкой кириллицы
};

// ---------------- СТРУКТУРА ХРАНИМОГО ОБЪЕКТА ----------------
enum E_PLACED
{
    bool:pl_Used,
    E_OBJ_TYPE:pl_Type,
    pl_ModelID,             // skin id / object id / icon id
    pl_CustomID,            // "ID" который задаёт админ (для NPC и Marker)
    pl_ActorID,             // хэндл CreateActor (NPC)
    pl_ObjectID,            // хэндл CreateObject (Object)
    pl_LabelID,             // хэндл 3D text label (NPC)
    pl_IconSlot,            // слот map icon (Marker)
    Text3D:pl_Text,         // тег для label (NPC и Надпись)
    pl_Color,               // цвет текста (Надпись)
    pl_Name[64],            // ник NPC (кириллица занимает 1 байт/симв. при charset=cp1251)
    pl_SignText[144],       // текст надписи (Надпись)
    Float:pl_X,
    Float:pl_Y,
    Float:pl_Z,
    Float:pl_Angle,         // угол разворота (используется для NPC)
    pl_CreatedBy[MAX_PLAYER_NAME],
    pl_SQLID                // ID строки в таблице objects_placed (0 = ещё не сохранён)
};

new PlacedObjects[MAX_PLACED_OBJECTS][E_PLACED];
new g_TotalObjects = 0;
new g_NextIconSlot = 0;

// Пресеты цветов для надписей (индекс совпадает с пунктом списка DLG_TXT_COLOR)
new g_SignColors[6] = {0xFFFFFFFF, 0xFF3333FF, 0x33FF33FF, 0x3399FFFF, 0xFFFF33FF, 0xFF9900FF};
new g_SignColorNames[6][12] = {"Белый", "Красный", "Зелёный", "Синий", "Жёлтый", "Оранжевый"};

// ---------------- ИЗБРАННОЕ (структура + хранилище) ----------------
enum E_FAVORITE
{
    bool:fav_Used,
    E_OBJ_TYPE:fav_Type,
    fav_ModelID,
    fav_CustomID,
    fav_Name[64],
    fav_SignText[144],
    fav_Color,
    fav_Label[32],
    fav_CreatedBy[MAX_PLAYER_NAME],
    fav_SQLID
};
new Favorites[MAX_FAVORITES][E_FAVORITE];
new g_TotalFavorites = 0;

// ВАЖНО ПРО КИРИЛЛИЦУ: ник NPC и текст надписи вводятся игроком прямо в диалоге,
// поэтому кириллица приходит "как есть" — отдельного кода для этого не нужно.
// Единственное условие — в server.cfg должна быть строка charset=cp1251 (или
// нужная вам кодировка), иначе кириллица будет отображаться крякозябрами у
// части игроков. Это настройка сервера, а не скрипта.

// ---------------- ВРЕМЕННЫЕ ДАННЫЕ МАСТЕРА СОЗДАНИЯ ----------------
enum E_TEMP
{
    E_OBJ_TYPE:tmp_Type,
    tmp_ModelID,
    tmp_CustomID,
    tmp_Name[64],
    tmp_SignText[144],
    tmp_Color,
    Float:tmp_X,
    Float:tmp_Y,
    Float:tmp_Z,
    tmp_ListIndex,          // индекс выбранного объекта в списке (для удаления/перемещения)
    Float:tmp_MoveStep,     // текущий шаг перемещения (для мобильного "нюджера")
    Float:tmp_OrigX,        // исходная позиция (для отмены перемещения)
    Float:tmp_OrigY,
    Float:tmp_OrigZ,
    tmp_MenuOffset,         // сколько первых строк диалога - инфо-шапка (не пункты меню)
    tmp_FavLabel[32],       // название пункта избранного (вводится при добавлении)
    tmp_FavIndex            // индекс избранного, с которым сейчас работаем (действия/переименование)
};
new CreationTemp[MAX_PLAYERS][E_TEMP];

// ---------------- ID ДИАЛОГОВ ----------------
#define DLG_MAIN_MENU       30000

#define DLG_NPC_SKIN        30001
#define DLG_NPC_NAME        30002
#define DLG_NPC_ID          30003
#define DLG_NPC_POSCHOICE   30004
#define DLG_NPC_POSMANUAL   30005
#define DLG_NPC_CONFIRM     30006

#define DLG_OBJ_MODEL       30010
#define DLG_OBJ_POSCHOICE   30011
#define DLG_OBJ_POSMANUAL   30012
#define DLG_OBJ_CONFIRM     30013

#define DLG_MRK_ICON        30020
#define DLG_MRK_ID          30021
#define DLG_MRK_POSCHOICE   30022
#define DLG_MRK_POSMANUAL   30023
#define DLG_MRK_CONFIRM     30024

#define DLG_TXT_TEXT        30025
#define DLG_TXT_COLOR       30026
#define DLG_TXT_POSCHOICE   30027
#define DLG_TXT_POSMANUAL   30028
#define DLG_TXT_CONFIRM     30029

#define DLG_LIST_OBJECTS    30030
#define DLG_OBJECT_ACTIONS  30031
#define DLG_DELETE_CONFIRM  30032

#define DLG_MOVE_MENU       30040
#define DLG_MOVE_STEP       30041
#define DLG_LIST_EMPTY_INFO 30033

#define DLG_FAV_LIST            30050
#define DLG_FAV_TYPE_CHOICE     30051
#define DLG_FAV_NPC_SKIN        30052
#define DLG_FAV_NPC_NAME        30053
#define DLG_FAV_OBJ_MODEL       30054
#define DLG_FAV_MRK_ICON        30055
#define DLG_FAV_MRK_ID          30056
#define DLG_FAV_TXT_TEXT        30057
#define DLG_FAV_TXT_COLOR       30058
#define DLG_FAV_LABEL           30059
#define DLG_FAV_ACTIONS         30060
#define DLG_FAV_RENAME          30061
#define DLG_FAV_DELETE_CONFIRM  30062

// ---------------- ПРОВЕРКА ПРАВ ----------------
stock IsPlacerAdmin(playerid)
{
    return GetPlayerAdminEx(playerid) >= OBJPLACER_ADMIN_LVL;
}

// ================= КОМАНДА =================
CMD:objects(playerid, params[])
{
    if(!IsPlacerAdmin(playerid))
        return SendClientMessage(playerid, 0xFF3333AA, "У вас нет доступа к этой команде.");

    ShowMainMenu(playerid);
    return 1;
}
alias:objects("obj")

// ================= ГЛАВНОЕ МЕНЮ =================
ShowMainMenu(playerid)
{
    new str[300];
    format(str, sizeof(str),
        "{FFFFFF}Создать NPC\n"\
        "{FFFFFF}Создать объект\n"\
        "{FFFFFF}Создать маркер\n"\
        "{FFFFFF}Создать надпись\n"\
        "{ADD8E6}Список созданных объектов (%d)\n"\
        "{FFCC00}Избранное (%d)", g_TotalObjects, g_TotalFavorites);

    ShowPlayerDialog(playerid, DLG_MAIN_MENU, DIALOG_STYLE_LIST,
        "Система установки объектов", str, "Выбрать", "Закрыть");
}

// ================= МАСТЕР: NPC =================
StartNPCWizard(playerid)
{
    CreationTemp[playerid][tmp_Type] = TYPE_NPC;
    ShowPlayerDialog(playerid, DLG_NPC_SKIN, DIALOG_STYLE_INPUT,
        "Создание NPC (Шаг 1/4)",
        "Введите ID скина NPC (число, например 0-311):",
        "Далее", "Отмена");
}

// ================= МАСТЕР: OBJECT =================
StartObjectWizard(playerid)
{
    CreationTemp[playerid][tmp_Type] = TYPE_OBJECT;
    ShowPlayerDialog(playerid, DLG_OBJ_MODEL, DIALOG_STYLE_INPUT,
        "Создание объекта (Шаг 1/2)",
        "Введите ID модели объекта (например 1225):",
        "Далее", "Отмена");
}

// ================= МАСТЕР: MARKER =================
StartMarkerWizard(playerid)
{
    CreationTemp[playerid][tmp_Type] = TYPE_MARKER;
    ShowPlayerDialog(playerid, DLG_MRK_ICON, DIALOG_STYLE_INPUT,
        "Создание маркера (Шаг 1/3)",
        "Введите ID иконки маркера на радаре (0-62):",
        "Далее", "Отмена");
}

// ================= МАСТЕР: НАДПИСЬ (TEXT) =================
StartTextWizard(playerid)
{
    CreationTemp[playerid][tmp_Type] = TYPE_TEXT;
    ShowPlayerDialog(playerid, DLG_TXT_TEXT, DIALOG_STYLE_INPUT,
        "Создание надписи (Шаг 1/3)",
        "Введите текст надписи (поддерживается кириллица, до 128 символов):",
        "Далее", "Отмена");
}

// ================= ВЫБОР КООРДИНАТ (общий для всех типов) =================
ShowPosChoice(playerid, dlgid, headertext[])
{
    ShowPlayerDialog(playerid, dlgid, DIALOG_STYLE_LIST, headertext,
        "{FFFFFF}Создать на моей текущей позиции\n"\
        "{FFFFFF}Указать координаты вручную",
        "Выбрать", "Назад");
}

// ================= ПОДТВЕРЖДЕНИЕ =================
ShowNPCConfirm(playerid)
{
    new str[400];
    format(str, sizeof(str),
        "{FFFFFF}Проверьте данные перед созданием:\n\n"\
        "{ADD8E6}Тип:{FFFFFF} NPC\n"\
        "{ADD8E6}Скин ID:{FFFFFF} %d\n"\
        "{ADD8E6}Ник:{FFFFFF} %s\n"\
        "{ADD8E6}Пользовательский ID:{FFFFFF} %d\n"\
        "{ADD8E6}Координаты:{FFFFFF} %.2f, %.2f, %.2f",
        CreationTemp[playerid][tmp_ModelID],
        CreationTemp[playerid][tmp_Name],
        CreationTemp[playerid][tmp_CustomID],
        CreationTemp[playerid][tmp_X],
        CreationTemp[playerid][tmp_Y],
        CreationTemp[playerid][tmp_Z]);

    ShowPlayerDialog(playerid, DLG_NPC_CONFIRM, DIALOG_STYLE_MSGBOX,
        "Подтверждение создания", str, "Создать", "Отмена");
}

ShowObjectConfirm(playerid)
{
    new str[400];
    format(str, sizeof(str),
        "{FFFFFF}Проверьте данные перед созданием:\n\n"\
        "{ADD8E6}Тип:{FFFFFF} Объект\n"\
        "{ADD8E6}ID модели:{FFFFFF} %d\n"\
        "{ADD8E6}Координаты:{FFFFFF} %.2f, %.2f, %.2f",
        CreationTemp[playerid][tmp_ModelID],
        CreationTemp[playerid][tmp_X],
        CreationTemp[playerid][tmp_Y],
        CreationTemp[playerid][tmp_Z]);

    ShowPlayerDialog(playerid, DLG_OBJ_CONFIRM, DIALOG_STYLE_MSGBOX,
        "Подтверждение создания", str, "Создать", "Отмена");
}

ShowMarkerConfirm(playerid)
{
    new str[400];
    format(str, sizeof(str),
        "{FFFFFF}Проверьте данные перед созданием:\n\n"\
        "{ADD8E6}Тип:{FFFFFF} Маркер\n"\
        "{ADD8E6}ID иконки:{FFFFFF} %d\n"\
        "{ADD8E6}Пользовательский ID:{FFFFFF} %d\n"\
        "{ADD8E6}Координаты:{FFFFFF} %.2f, %.2f, %.2f",
        CreationTemp[playerid][tmp_ModelID],
        CreationTemp[playerid][tmp_CustomID],
        CreationTemp[playerid][tmp_X],
        CreationTemp[playerid][tmp_Y],
        CreationTemp[playerid][tmp_Z]);

    ShowPlayerDialog(playerid, DLG_MRK_CONFIRM, DIALOG_STYLE_MSGBOX,
        "Подтверждение создания", str, "Создать", "Отмена");
}

ShowTextConfirm(playerid)
{
    new str[400];
    format(str, sizeof(str),
        "{FFFFFF}Проверьте данные перед созданием:\n\n"\
        "{ADD8E6}Тип:{FFFFFF} Надпись\n"\
        "{ADD8E6}Текст:{FFFFFF} %s\n"\
        "{ADD8E6}Цвет:{FFFFFF} %s\n"\
        "{ADD8E6}Координаты:{FFFFFF} %.2f, %.2f, %.2f",
        CreationTemp[playerid][tmp_SignText],
        g_SignColorNames[CreationTemp[playerid][tmp_Color]],
        CreationTemp[playerid][tmp_X],
        CreationTemp[playerid][tmp_Y],
        CreationTemp[playerid][tmp_Z]);

    ShowPlayerDialog(playerid, DLG_TXT_CONFIRM, DIALOG_STYLE_MSGBOX,
        "Подтверждение создания", str, "Создать", "Отмена");
}

// ================= ПОИСК СВОБОДНОГО СЛОТА =================
FindFreeSlot()
{
    for(new i = 0; i < MAX_PLACED_OBJECTS; i++)
    {
        if(!PlacedObjects[i][pl_Used]) return i;
    }
    return -1;
}

// ================= СОЗДАНИЕ NPC =================
CreatePlacedNPC(playerid)
{
    new slot = FindFreeSlot();
    if(slot == -1)
        return SendClientMessage(playerid, 0xFF3333AA, "Достигнут лимит объектов (500).");

    PlacedObjects[slot][pl_Used]     = true;
    PlacedObjects[slot][pl_Type]     = TYPE_NPC;
    PlacedObjects[slot][pl_ModelID]  = CreationTemp[playerid][tmp_ModelID];
    PlacedObjects[slot][pl_CustomID] = CreationTemp[playerid][tmp_CustomID];
    PlacedObjects[slot][pl_X]        = CreationTemp[playerid][tmp_X];
    PlacedObjects[slot][pl_Y]        = CreationTemp[playerid][tmp_Y];
    PlacedObjects[slot][pl_Z]        = CreationTemp[playerid][tmp_Z];
    format(PlacedObjects[slot][pl_Name], 64, "%s", CreationTemp[playerid][tmp_Name]);
    GetPlayerName(playerid, PlacedObjects[slot][pl_CreatedBy], MAX_PLAYER_NAME);

    GetPlayerFacingAngle(playerid, PlacedObjects[slot][pl_Angle]);
    SpawnNPCVisual(slot);

    g_TotalObjects++;
    ObjectPlacer_Persist(slot);
    SendClientMessage(playerid, 0x33FF33AA, "NPC успешно создан.");
    ResetTemp(playerid);
}

// создаёт актора и 3D-надпись по уже заполненным данным PlacedObjects[slot]
// (используется как при создании через мастер, так и при загрузке из БД)
SpawnNPCVisual(slot)
{
    PlacedObjects[slot][pl_ActorID] = CreateActor(PlacedObjects[slot][pl_ModelID],
        PlacedObjects[slot][pl_X], PlacedObjects[slot][pl_Y], PlacedObjects[slot][pl_Z],
        PlacedObjects[slot][pl_Angle]);

    new str[128];
    format(str, sizeof(str), "%s\n{FFFF00}ID: %d", PlacedObjects[slot][pl_Name], PlacedObjects[slot][pl_CustomID]);
    PlacedObjects[slot][pl_Text] = Create3DTextLabel(str, 0x00FF00FF,
        PlacedObjects[slot][pl_X], PlacedObjects[slot][pl_Y], PlacedObjects[slot][pl_Z] + 1.0,
        20.0, 0, 1);
}

// ================= СОЗДАНИЕ ОБЪЕКТА =================
CreatePlacedObjectEntry(playerid)
{
    new slot = FindFreeSlot();
    if(slot == -1)
        return SendClientMessage(playerid, 0xFF3333AA, "Достигнут лимит объектов (500).");

    PlacedObjects[slot][pl_Used]    = true;
    PlacedObjects[slot][pl_Type]    = TYPE_OBJECT;
    PlacedObjects[slot][pl_ModelID] = CreationTemp[playerid][tmp_ModelID];
    PlacedObjects[slot][pl_X]       = CreationTemp[playerid][tmp_X];
    PlacedObjects[slot][pl_Y]       = CreationTemp[playerid][tmp_Y];
    PlacedObjects[slot][pl_Z]       = CreationTemp[playerid][tmp_Z];
    GetPlayerName(playerid, PlacedObjects[slot][pl_CreatedBy], MAX_PLAYER_NAME);

    SpawnObjectVisual(slot);

    g_TotalObjects++;
    ObjectPlacer_Persist(slot);
    SendClientMessage(playerid, 0x33FF33AA, "Объект успешно создан.");
    ResetTemp(playerid);
}

SpawnObjectVisual(slot)
{
    PlacedObjects[slot][pl_ObjectID] = CreateObject(PlacedObjects[slot][pl_ModelID],
        PlacedObjects[slot][pl_X], PlacedObjects[slot][pl_Y], PlacedObjects[slot][pl_Z],
        0.0, 0.0, 0.0);
}

// ================= СОЗДАНИЕ МАРКЕРА =================
CreatePlacedMarker(playerid)
{
    new slot = FindFreeSlot();
    if(slot == -1)
        return SendClientMessage(playerid, 0xFF3333AA, "Достигнут лимит объектов (500).");

    PlacedObjects[slot][pl_Used]     = true;
    PlacedObjects[slot][pl_Type]     = TYPE_MARKER;
    PlacedObjects[slot][pl_ModelID]  = CreationTemp[playerid][tmp_ModelID]; // icon id
    PlacedObjects[slot][pl_CustomID] = CreationTemp[playerid][tmp_CustomID];
    PlacedObjects[slot][pl_X]        = CreationTemp[playerid][tmp_X];
    PlacedObjects[slot][pl_Y]        = CreationTemp[playerid][tmp_Y];
    PlacedObjects[slot][pl_Z]        = CreationTemp[playerid][tmp_Z];
    GetPlayerName(playerid, PlacedObjects[slot][pl_CreatedBy], MAX_PLAYER_NAME);

    PlacedObjects[slot][pl_IconSlot] = g_NextIconSlot;
    g_NextIconSlot = (g_NextIconSlot + 1) % MAX_ICON_SLOTS;

    for(new i = 0; i < MAX_PLAYERS; i++)
    {
        if(IsPlayerConnected(i))
        {
            SetPlayerMapIcon(i, PlacedObjects[slot][pl_IconSlot],
                PlacedObjects[slot][pl_X], PlacedObjects[slot][pl_Y], PlacedObjects[slot][pl_Z],
                PlacedObjects[slot][pl_ModelID], 0, MAPICON_LOCAL);
        }
    }

    g_TotalObjects++;
    ObjectPlacer_Persist(slot);
    SendClientMessage(playerid, 0x33FF33AA, "Маркер успешно создан.");
    ResetTemp(playerid);
}

// ================= СОЗДАНИЕ НАДПИСИ =================
CreatePlacedText(playerid)
{
    new slot = FindFreeSlot();
    if(slot == -1)
        return SendClientMessage(playerid, 0xFF3333AA, "Достигнут лимит объектов (500).");

    PlacedObjects[slot][pl_Used]  = true;
    PlacedObjects[slot][pl_Type]  = TYPE_TEXT;
    PlacedObjects[slot][pl_Color] = g_SignColors[CreationTemp[playerid][tmp_Color]];
    PlacedObjects[slot][pl_X]     = CreationTemp[playerid][tmp_X];
    PlacedObjects[slot][pl_Y]     = CreationTemp[playerid][tmp_Y];
    PlacedObjects[slot][pl_Z]     = CreationTemp[playerid][tmp_Z];
    format(PlacedObjects[slot][pl_SignText], 144, "%s", CreationTemp[playerid][tmp_SignText]);
    GetPlayerName(playerid, PlacedObjects[slot][pl_CreatedBy], MAX_PLAYER_NAME);

    SpawnTextVisual(slot);

    g_TotalObjects++;
    ObjectPlacer_Persist(slot);
    SendClientMessage(playerid, 0x33FF33AA, "Надпись успешно создана.");
    ResetTemp(playerid);
}

SpawnTextVisual(slot)
{
    PlacedObjects[slot][pl_Text] = Create3DTextLabel(PlacedObjects[slot][pl_SignText],
        PlacedObjects[slot][pl_Color],
        PlacedObjects[slot][pl_X], PlacedObjects[slot][pl_Y], PlacedObjects[slot][pl_Z],
        20.0, 0, 1);
}

ResetTemp(playerid)
{
    CreationTemp[playerid][tmp_ModelID]  = 0;
    CreationTemp[playerid][tmp_CustomID] = 0;
    CreationTemp[playerid][tmp_Name][0]  = 0;
    CreationTemp[playerid][tmp_SignText][0] = 0;
    CreationTemp[playerid][tmp_Color]    = 0;
    CreationTemp[playerid][tmp_X] = 0.0;
    CreationTemp[playerid][tmp_Y] = 0.0;
    CreationTemp[playerid][tmp_Z] = 0.0;
}

// ================= СОХРАНЕНИЕ / ЗАГРУЗКА В БД =================

// сохраняет объект слота slot в таблицу objects_placed (INSERT, если ещё
// не сохранён, иначе шлёт свежую строку с новым ID — используется только
// один раз сразу после создания, поэтому всегда INSERT)
ObjectPlacer_Persist(slot)
{
    new query[768];
    mysql_format(mysql, query, sizeof query,
        "INSERT INTO objects_placed (type, model_id, custom_id, name, sign_text, color, x, y, z, angle, created_by) \
         VALUES (%d, %d, %d, '%e', '%e', %d, %f, %f, %f, %f, '%e')",
        _:PlacedObjects[slot][pl_Type], PlacedObjects[slot][pl_ModelID], PlacedObjects[slot][pl_CustomID],
        PlacedObjects[slot][pl_Name], PlacedObjects[slot][pl_SignText], PlacedObjects[slot][pl_Color],
        PlacedObjects[slot][pl_X], PlacedObjects[slot][pl_Y], PlacedObjects[slot][pl_Z],
        PlacedObjects[slot][pl_Angle], PlacedObjects[slot][pl_CreatedBy]);
    mysql_tquery(mysql, query, "OnPlacedObjectInserted", "i", slot);
}

forward OnPlacedObjectInserted(slot);
public OnPlacedObjectInserted(slot)
{
    if(PlacedObjects[slot][pl_Used]) // объект мог быть удалён, пока запрос летал
        PlacedObjects[slot][pl_SQLID] = cache_insert_id();
    return 1;
}

// обновляет позицию в БД (вызывается из SaveMovedPosition)
ObjectPlacer_PersistPosition(slot)
{
    if(PlacedObjects[slot][pl_SQLID] <= 0) return 0;

    new query[160];
    mysql_format(mysql, query, sizeof query,
        "UPDATE objects_placed SET x=%f, y=%f, z=%f WHERE id=%d LIMIT 1",
        PlacedObjects[slot][pl_X], PlacedObjects[slot][pl_Y], PlacedObjects[slot][pl_Z],
        PlacedObjects[slot][pl_SQLID]);
    mysql_tquery(mysql, query);
    return 1;
}

// удаляет строку из БД (вызывается из DeletePlacedObject)
ObjectPlacer_PersistDelete(slot)
{
    if(PlacedObjects[slot][pl_SQLID] <= 0) return 0;

    new query[96];
    mysql_format(mysql, query, sizeof query,
        "DELETE FROM objects_placed WHERE id=%d LIMIT 1", PlacedObjects[slot][pl_SQLID]);
    mysql_tquery(mysql, query);
    return 1;
}

// вызывается один раз из OnGameModeInit — поднимает все объекты после рестарта
ObjectPlacer_LoadFromDB()
{
    mysql_tquery(mysql, "SELECT * FROM objects_placed", "OnPlacedObjectsLoaded", "");
}

forward OnPlacedObjectsLoaded();
public OnPlacedObjectsLoaded()
{
    new rows = cache_num_rows();
    for(new i = 0; i < rows; i++)
    {
        new slot = FindFreeSlot();
        if(slot == -1)
        {
            printf("[object_placer] Достигнут лимит MAX_PLACED_OBJECTS при загрузке из БД, часть объектов не загружена.");
            break;
        }

        new type_val = cache_get_field_content_int(i, "type");

        PlacedObjects[slot][pl_Used]     = true;
        PlacedObjects[slot][pl_Type]     = E_OBJ_TYPE:type_val;
        PlacedObjects[slot][pl_ModelID]  = cache_get_field_content_int(i, "model_id");
        PlacedObjects[slot][pl_CustomID] = cache_get_field_content_int(i, "custom_id");
        PlacedObjects[slot][pl_Color]    = cache_get_field_content_int(i, "color");
        PlacedObjects[slot][pl_SQLID]    = cache_get_field_content_int(i, "id");

        PlacedObjects[slot][pl_X]     = cache_get_field_content_float(i, "x");
        PlacedObjects[slot][pl_Y]     = cache_get_field_content_float(i, "y");
        PlacedObjects[slot][pl_Z]     = cache_get_field_content_float(i, "z");
        PlacedObjects[slot][pl_Angle] = cache_get_field_content_float(i, "angle");

        cache_get_field_content(i, "name", PlacedObjects[slot][pl_Name]);
        cache_get_field_content(i, "sign_text", PlacedObjects[slot][pl_SignText]);
        cache_get_field_content(i, "created_by", PlacedObjects[slot][pl_CreatedBy]);

        switch(PlacedObjects[slot][pl_Type])
        {
            case TYPE_NPC: { SpawnNPCVisual(slot); }
            case TYPE_OBJECT: { SpawnObjectVisual(slot); }
            case TYPE_TEXT: { SpawnTextVisual(slot); }
            case TYPE_MARKER:
            {
                // иконки маркеров рассылаются игрокам через ObjectPlacer_OnPlayerConnect,
                // здесь только резервируем слот иконки
                PlacedObjects[slot][pl_IconSlot] = g_NextIconSlot;
                g_NextIconSlot = (g_NextIconSlot + 1) % MAX_ICON_SLOTS;
            }
        }

        g_TotalObjects++;
    }

    printf("[object_placer] Загружено объектов из БД: %d", g_TotalObjects);
    return 1;
}

// ================= СПИСОК ОБЪЕКТОВ =================
ShowObjectsList(playerid)
{
    new str[2048], count = 0;
    strcat(str, "Тип\tID\tИнфо\n");

    for(new i = 0; i < MAX_PLACED_OBJECTS; i++)
    {
        if(!PlacedObjects[i][pl_Used]) continue;

        new objline[128];
        switch(PlacedObjects[i][pl_Type])
        {
            case TYPE_NPC:
            {
                format(objline, sizeof(objline), "NPC\t%d\t%s (скин %d)\n",
                    PlacedObjects[i][pl_CustomID], PlacedObjects[i][pl_Name], PlacedObjects[i][pl_ModelID]);
            }
            case TYPE_OBJECT:
            {
                format(objline, sizeof(objline), "Объект\t-\tМодель %d\n", PlacedObjects[i][pl_ModelID]);
            }
            case TYPE_MARKER:
            {
                format(objline, sizeof(objline), "Маркер\t%d\tИконка %d\n",
                    PlacedObjects[i][pl_CustomID], PlacedObjects[i][pl_ModelID]);
            }
            case TYPE_TEXT:
            {
                format(objline, sizeof(objline), "Надпись\t-\t%.20s\n", PlacedObjects[i][pl_SignText]);
            }
        }
        strcat(str, objline);
        count++;
    }

    if(count == 0)
    {
        // ВАЖНО: отдельный dialogid, отличный от DLG_LIST_OBJECTS — иначе
        // ответ на это сообщение попадает в обработчик списка, всегда получает
        // realindex == -1 и снова открывает то же сообщение (бесконечный цикл).
        ShowPlayerDialog(playerid, DLG_LIST_EMPTY_INFO, DIALOG_STYLE_MSGBOX,
            "Список объектов", "Пока не создано ни одного объекта.", "OK", "");
        return;
    }

    ShowPlayerDialog(playerid, DLG_LIST_OBJECTS, DIALOG_STYLE_TABLIST_HEADERS, "Список объектов", str, "Выбрать", "Назад");
}

// CountLines() уже объявлена в include/system/blogger_system.pwn (подключается
// раньше этого файла) - переиспользуем её здесь же для ShowObjectActions/ShowMoveMenu.

// строим индекс-мэппинг строк списка -> реальный индекс в массиве
// (нужно, т.к. список показывает только использованные слоты подряд)
GetRealIndexFromListRow(row)
{
    new count = -1;
    for(new i = 0; i < MAX_PLACED_OBJECTS; i++)
    {
        if(!PlacedObjects[i][pl_Used]) continue;
        count++;
        if(count == row) return i;
    }
    return -1;
}

ShowObjectActions(playerid, realindex)
{
    CreationTemp[playerid][tmp_ListIndex] = realindex;

    new str[400], typestr[16];
    switch(PlacedObjects[realindex][pl_Type])
    {
        case TYPE_NPC: { typestr = "NPC"; }
        case TYPE_OBJECT: { typestr = "Объект"; }
        case TYPE_MARKER: { typestr = "Маркер"; }
        case TYPE_TEXT: { typestr = "Надпись"; }
    }

    // Инфо-шапка + пункты меню в одном диалоге. Число строк шапки СЧИТАЕТСЯ
    // автоматически (CountLines) и сохраняется в tmp_MenuOffset - обработчик
    // диалога вычитает его из listitem, поэтому индексы пунктов не зависят
    // от того, сколько строк занимает шапка.
    new header[200];
    format(header, sizeof(header),
        "{ADD8E6}Тип:{FFFFFF} %s\n{ADD8E6}Координаты:{FFFFFF} %.2f, %.2f, %.2f\n{ADD8E6}Создал:{FFFFFF} %s\n",
        typestr, PlacedObjects[realindex][pl_X], PlacedObjects[realindex][pl_Y], PlacedObjects[realindex][pl_Z],
        PlacedObjects[realindex][pl_CreatedBy]);
    CreationTemp[playerid][tmp_MenuOffset] = CountLines(header);

    format(str, sizeof(str),
        "%s{FFFFFF}Телепортироваться\n"\
        "{FFFFFF}Переместить (кнопками, для тача)\n"\
        "{FF3333}Удалить", header);

    ShowPlayerDialog(playerid, DLG_OBJECT_ACTIONS, DIALOG_STYLE_LIST, "Действия с объектом", str, "Выбрать", "Назад");
}

DeletePlacedObject(realindex)
{
    if(!PlacedObjects[realindex][pl_Used]) return;

    switch(PlacedObjects[realindex][pl_Type])
    {
        case TYPE_NPC:
        {
            if(IsValidActor(PlacedObjects[realindex][pl_ActorID]))
                DestroyActor(PlacedObjects[realindex][pl_ActorID]);
            Delete3DTextLabel(PlacedObjects[realindex][pl_Text]);
        }
        case TYPE_OBJECT:
        {
            if(IsValidObject(PlacedObjects[realindex][pl_ObjectID]))
                DestroyObject(PlacedObjects[realindex][pl_ObjectID]);
        }
        case TYPE_MARKER:
        {
            for(new i = 0; i < MAX_PLAYERS; i++)
            {
                if(IsPlayerConnected(i))
                    RemovePlayerMapIcon(i, PlacedObjects[realindex][pl_IconSlot]);
            }
        }
        case TYPE_TEXT:
        {
            Delete3DTextLabel(PlacedObjects[realindex][pl_Text]);
        }
    }

    ObjectPlacer_PersistDelete(realindex);

    PlacedObjects[realindex][pl_Used] = false;
    PlacedObjects[realindex][pl_SQLID] = 0;
    g_TotalObjects--;
}

// ================= ПЕРЕМЕЩЕНИЕ ОБЪЕКТА (ТАЧ-ФРЕНДЛИ) =================
// Работает кнопками, без мыши и без курсора — подходит для мобильного клиента.
// Для NPC/Object позиция двигается в реальном времени, чтобы было видно в игре.
// Для Marker позиция применяется только при сохранении (иконка на радаре).

StartMoveWizard(playerid, realindex)
{
    CreationTemp[playerid][tmp_ListIndex] = realindex;
    CreationTemp[playerid][tmp_MoveStep]  = 1.0;

    CreationTemp[playerid][tmp_X] = PlacedObjects[realindex][pl_X];
    CreationTemp[playerid][tmp_Y] = PlacedObjects[realindex][pl_Y];
    CreationTemp[playerid][tmp_Z] = PlacedObjects[realindex][pl_Z];

    CreationTemp[playerid][tmp_OrigX] = PlacedObjects[realindex][pl_X];
    CreationTemp[playerid][tmp_OrigY] = PlacedObjects[realindex][pl_Y];
    CreationTemp[playerid][tmp_OrigZ] = PlacedObjects[realindex][pl_Z];

    ShowMoveMenu(playerid);
}

ShowMoveMenu(playerid)
{
    new realindex = CreationTemp[playerid][tmp_ListIndex];
    new str[400];
    // Инфо-шапка (позиция) снова внутри диалога - смещение считается
    // автоматически через CountLines(), см. комментарий в ShowObjectActions.
    new header[80];
    format(header, sizeof(header), "{ADD8E6}Текущая позиция:{FFFFFF} %.2f, %.2f, %.2f\n",
        CreationTemp[playerid][tmp_X], CreationTemp[playerid][tmp_Y], CreationTemp[playerid][tmp_Z]);
    CreationTemp[playerid][tmp_MenuOffset] = CountLines(header);

    format(str, sizeof(str),
        "%s{FFFF00}Шаг: %.1f м (нажмите, чтобы сменить)\n"\
        "{FFFFFF}X +\n"\
        "{FFFFFF}X -\n"\
        "{FFFFFF}Y +\n"\
        "{FFFFFF}Y -\n"\
        "{FFFFFF}Z +\n"\
        "{FFFFFF}Z -\n"\
        "{33FF33}Сохранить позицию\n"\
        "{FF3333}Отмена (вернуть как было)",
        header, CreationTemp[playerid][tmp_MoveStep]);

    new caption[48];
    switch(PlacedObjects[realindex][pl_Type])
    {
        case TYPE_NPC:    { caption = "Перемещение NPC"; }
        case TYPE_OBJECT: { caption = "Перемещение объекта"; }
        case TYPE_MARKER: { caption = "Перемещение маркера"; }
        case TYPE_TEXT:   { caption = "Перемещение надписи"; }
    }

    ShowPlayerDialog(playerid, DLG_MOVE_MENU, DIALOG_STYLE_LIST, caption, str, "Выбрать", "Назад");
}

ApplyLivePreview(playerid)
{
    new realindex = CreationTemp[playerid][tmp_ListIndex];
    new Float:x = CreationTemp[playerid][tmp_X];
    new Float:y = CreationTemp[playerid][tmp_Y];
    new Float:z = CreationTemp[playerid][tmp_Z];

    switch(PlacedObjects[realindex][pl_Type])
    {
        case TYPE_NPC:
        {
            if(IsValidActor(PlacedObjects[realindex][pl_ActorID]))
                SetActorPos(PlacedObjects[realindex][pl_ActorID], x, y, z);

            // подпись над головой тоже двигаем вживую, иначе она "отстаёт" от актора
            if(PlacedObjects[realindex][pl_Text] != Text3D:INVALID_3DTEXT_ID)
                Delete3DTextLabel(PlacedObjects[realindex][pl_Text]);
            new lbl[128];
            format(lbl, sizeof(lbl), "%s\n{FFFF00}ID: %d", PlacedObjects[realindex][pl_Name], PlacedObjects[realindex][pl_CustomID]);
            PlacedObjects[realindex][pl_Text] = Create3DTextLabel(lbl, 0x00FF00FF, x, y, z + 1.0, 20.0, 0, 1);
        }
        case TYPE_OBJECT:
        {
            // SetObjectPos does not always refresh the object for already-streamed-in
            // clients -> destroy + recreate at the new position instead
            if(IsValidObject(PlacedObjects[realindex][pl_ObjectID]))
                DestroyObject(PlacedObjects[realindex][pl_ObjectID]);

            PlacedObjects[realindex][pl_ObjectID] = CreateObject(PlacedObjects[realindex][pl_ModelID],
                x, y, z, 0.0, 0.0, 0.0);
        }
        case TYPE_MARKER:
        {
            // живое превью иконки на радаре: пересылаем её на новую позицию
            // при каждом нажатии, чтобы было видно движение сразу
            for(new i = 0; i < MAX_PLAYERS; i++)
            {
                if(IsPlayerConnected(i))
                {
                    SetPlayerMapIcon(i, PlacedObjects[realindex][pl_IconSlot], x, y, z,
                        PlacedObjects[realindex][pl_ModelID], 0, MAPICON_LOCAL);
                }
            }
        }
        case TYPE_TEXT:
        {
            // 3D text label не двигается без пересоздания - пересоздаём на каждый тап,
            // чтобы движение было видно сразу, а не только после сохранения
            if(PlacedObjects[realindex][pl_Text] != Text3D:INVALID_3DTEXT_ID)
                Delete3DTextLabel(PlacedObjects[realindex][pl_Text]);
            PlacedObjects[realindex][pl_Text] = Create3DTextLabel(PlacedObjects[realindex][pl_SignText],
                PlacedObjects[realindex][pl_Color], x, y, z, 20.0, 0, 1);
        }
    }
}

SaveMovedPosition(playerid)
{
    new realindex = CreationTemp[playerid][tmp_ListIndex];

    PlacedObjects[realindex][pl_X] = CreationTemp[playerid][tmp_X];
    PlacedObjects[realindex][pl_Y] = CreationTemp[playerid][tmp_Y];
    PlacedObjects[realindex][pl_Z] = CreationTemp[playerid][tmp_Z];

    switch(PlacedObjects[realindex][pl_Type])
    {
        case TYPE_NPC:
        {
            // 3D text label нельзя просто сдвинуть — пересоздаём на новой позиции
            Delete3DTextLabel(PlacedObjects[realindex][pl_Text]);
            new str[64];
            format(str, sizeof(str), "%s\n{FFFF00}ID: %d", PlacedObjects[realindex][pl_Name], PlacedObjects[realindex][pl_CustomID]);
            PlacedObjects[realindex][pl_Text] = Create3DTextLabel(str, 0x00FF00FF,
                PlacedObjects[realindex][pl_X], PlacedObjects[realindex][pl_Y], PlacedObjects[realindex][pl_Z] + 1.0,
                20.0, 0, 1);
        }
        case TYPE_MARKER:
        {
            for(new i = 0; i < MAX_PLAYERS; i++)
            {
                if(IsPlayerConnected(i))
                {
                    SetPlayerMapIcon(i, PlacedObjects[realindex][pl_IconSlot],
                        PlacedObjects[realindex][pl_X], PlacedObjects[realindex][pl_Y], PlacedObjects[realindex][pl_Z],
                        PlacedObjects[realindex][pl_ModelID], 0, MAPICON_LOCAL);
                }
            }
        }
        case TYPE_TEXT:
        {
            Delete3DTextLabel(PlacedObjects[realindex][pl_Text]);
            PlacedObjects[realindex][pl_Text] = Create3DTextLabel(PlacedObjects[realindex][pl_SignText],
                PlacedObjects[realindex][pl_Color],
                PlacedObjects[realindex][pl_X], PlacedObjects[realindex][pl_Y], PlacedObjects[realindex][pl_Z],
                20.0, 0, 1);
        }
    }

    ObjectPlacer_PersistPosition(realindex);
    SendClientMessage(playerid, 0x33FF33AA, "Новая позиция сохранена.");
}

CancelMove(playerid)
{
    new realindex = CreationTemp[playerid][tmp_ListIndex];
    CreationTemp[playerid][tmp_X] = CreationTemp[playerid][tmp_OrigX];
    CreationTemp[playerid][tmp_Y] = CreationTemp[playerid][tmp_OrigY];
    CreationTemp[playerid][tmp_Z] = CreationTemp[playerid][tmp_OrigZ];
    ApplyLivePreview(playerid); // вернуть NPC/объект на исходное место визуально
    SendClientMessage(playerid, 0xFFFF00AA, "Перемещение отменено, позиция возвращена.");
}

// ================= ПАРСИНГ КООРДИНАТ =================
// Формат ввода: "X,Y,Z" например: 1500.5,-1200.3,25.0
stock ParseCoords(const input[], &Float:x, &Float:y, &Float:z)
{
    if(sscanf(input, "p<,>fff", x, y, z)) return 0;
    return 1;
}

// ================= OnDialogResponse =================
ObjectPlacer_OnDialogResponse(playerid, dialogid, response, listitem, inputtext[])
{
    switch(dialogid)
    {
        // ---------- ГЛАВНОЕ МЕНЮ ----------
        case DLG_MAIN_MENU:
        {
            if(!response) return 1;
            switch(listitem)
            {
                case 0: { StartNPCWizard(playerid); }
                case 1: { StartObjectWizard(playerid); }
                case 2: { StartMarkerWizard(playerid); }
                case 3: { StartTextWizard(playerid); }
                case 4: { ShowObjectsList(playerid); }
                case 5: { ShowFavoritesList(playerid); }
            }
            return 1;
        }

        // ---------- NPC WIZARD ----------
        case DLG_NPC_SKIN:
        {
            if(!response) return 1;
            new skinid;
            if(sscanf(inputtext, "i", skinid) || skinid < 0)
            {
                SendClientMessage(playerid, 0xFF3333AA, "Некорректный ID скина. Попробуйте снова.");
                return StartNPCWizard(playerid);
            }
            CreationTemp[playerid][tmp_ModelID] = skinid;
            ShowPlayerDialog(playerid, DLG_NPC_NAME, DIALOG_STYLE_INPUT,
                "Создание NPC (Шаг 2/4)", "Введите ник NPC (поддерживается кириллица):", "Далее", "Отмена");
            return 1;
        }

        case DLG_NPC_NAME:
        {
            if(!response) return 1;
            utf8_to_cp1251(inputtext); // вход из диалога приходит в UTF-8 — переводим в cp1251
            if(strlen(inputtext) == 0 || strlen(inputtext) > 63)
            {
                SendClientMessage(playerid, 0xFF3333AA, "Ник должен быть от 1 до 63 символов.");
                return ShowPlayerDialog(playerid, DLG_NPC_NAME, DIALOG_STYLE_INPUT,
                    "Создание NPC (Шаг 2/4)", "Введите ник NPC (поддерживается кириллица):", "Далее", "Отмена");
            }
            format(CreationTemp[playerid][tmp_Name], 64, "%s", inputtext);
            ShowPlayerDialog(playerid, DLG_NPC_ID, DIALOG_STYLE_INPUT,
                "Создание NPC (Шаг 3/4)", "Введите пользовательский ID (число для идентификации NPC):",
                "Далее", "Отмена");
            return 1;
        }

        case DLG_NPC_ID:
        {
            if(!response) return 1;
            new cid;
            if(sscanf(inputtext, "i", cid))
            {
                SendClientMessage(playerid, 0xFF3333AA, "Введите корректное число.");
                return ShowPlayerDialog(playerid, DLG_NPC_ID, DIALOG_STYLE_INPUT,
                    "Создание NPC (Шаг 3/4)", "Введите пользовательский ID:", "Далее", "Отмена");
            }
            CreationTemp[playerid][tmp_CustomID] = cid;
            ShowPosChoice(playerid, DLG_NPC_POSCHOICE, "Создание NPC (Шаг 4/4)");
            return 1;
        }

        case DLG_NPC_POSCHOICE:
        {
            if(!response) return 1;
            if(listitem == 0)
            {
                new Float:x, Float:y, Float:z;
                GetPlayerPos(playerid, x, y, z);
                CreationTemp[playerid][tmp_X] = x;
                CreationTemp[playerid][tmp_Y] = y;
                CreationTemp[playerid][tmp_Z] = z;
                ShowNPCConfirm(playerid);
            }
            else
            {
                ShowPlayerDialog(playerid, DLG_NPC_POSMANUAL, DIALOG_STYLE_INPUT,
                    "Координаты", "Введите координаты в формате X,Y,Z:", "Далее", "Отмена");
            }
            return 1;
        }

        case DLG_NPC_POSMANUAL:
        {
            if(!response) return 1;
            new Float:x, Float:y, Float:z;
            if(!ParseCoords(inputtext, x, y, z))
            {
                SendClientMessage(playerid, 0xFF3333AA, "Неверный формат. Пример: 1500.5,-1200.3,25.0");
                return ShowPlayerDialog(playerid, DLG_NPC_POSMANUAL, DIALOG_STYLE_INPUT,
                    "Координаты", "Введите координаты в формате X,Y,Z:", "Далее", "Отмена");
            }
            CreationTemp[playerid][tmp_X] = x;
            CreationTemp[playerid][tmp_Y] = y;
            CreationTemp[playerid][tmp_Z] = z;
            ShowNPCConfirm(playerid);
            return 1;
        }

        case DLG_NPC_CONFIRM:
        {
            if(response) CreatePlacedNPC(playerid);
            else { ResetTemp(playerid); SendClientMessage(playerid, 0xFFFF00AA, "Создание отменено."); }
            return 1;
        }

        // ---------- OBJECT WIZARD ----------
        case DLG_OBJ_MODEL:
        {
            if(!response) return 1;
            new modelid;
            if(sscanf(inputtext, "i", modelid) || modelid < 0)
            {
                SendClientMessage(playerid, 0xFF3333AA, "Некорректный ID модели.");
                return StartObjectWizard(playerid);
            }
            CreationTemp[playerid][tmp_ModelID] = modelid;
            ShowPosChoice(playerid, DLG_OBJ_POSCHOICE, "Создание объекта (Шаг 2/2)");
            return 1;
        }

        case DLG_OBJ_POSCHOICE:
        {
            if(!response) return 1;
            if(listitem == 0)
            {
                new Float:x, Float:y, Float:z;
                GetPlayerPos(playerid, x, y, z);
                CreationTemp[playerid][tmp_X] = x;
                CreationTemp[playerid][tmp_Y] = y;
                CreationTemp[playerid][tmp_Z] = z;
                ShowObjectConfirm(playerid);
            }
            else
            {
                ShowPlayerDialog(playerid, DLG_OBJ_POSMANUAL, DIALOG_STYLE_INPUT,
                    "Координаты", "Введите координаты в формате X,Y,Z:", "Далее", "Отмена");
            }
            return 1;
        }

        case DLG_OBJ_POSMANUAL:
        {
            if(!response) return 1;
            new Float:x, Float:y, Float:z;
            if(!ParseCoords(inputtext, x, y, z))
            {
                SendClientMessage(playerid, 0xFF3333AA, "Неверный формат. Пример: 1500.5,-1200.3,25.0");
                return ShowPlayerDialog(playerid, DLG_OBJ_POSMANUAL, DIALOG_STYLE_INPUT,
                    "Координаты", "Введите координаты в формате X,Y,Z:", "Далее", "Отмена");
            }
            CreationTemp[playerid][tmp_X] = x;
            CreationTemp[playerid][tmp_Y] = y;
            CreationTemp[playerid][tmp_Z] = z;
            ShowObjectConfirm(playerid);
            return 1;
        }

        case DLG_OBJ_CONFIRM:
        {
            if(response) CreatePlacedObjectEntry(playerid);
            else { ResetTemp(playerid); SendClientMessage(playerid, 0xFFFF00AA, "Создание отменено."); }
            return 1;
        }

        // ---------- MARKER WIZARD ----------
        case DLG_MRK_ICON:
        {
            if(!response) return 1;
            new iconid;
            if(sscanf(inputtext, "i", iconid) || iconid < 0 || iconid > 62)
            {
                SendClientMessage(playerid, 0xFF3333AA, "ID иконки должен быть от 0 до 62.");
                return StartMarkerWizard(playerid);
            }
            CreationTemp[playerid][tmp_ModelID] = iconid;
            ShowPlayerDialog(playerid, DLG_MRK_ID, DIALOG_STYLE_INPUT,
                "Создание маркера (Шаг 2/3)", "Введите пользовательский ID маркера:", "Далее", "Отмена");
            return 1;
        }

        case DLG_MRK_ID:
        {
            if(!response) return 1;
            new cid;
            if(sscanf(inputtext, "i", cid))
            {
                SendClientMessage(playerid, 0xFF3333AA, "Введите корректное число.");
                return ShowPlayerDialog(playerid, DLG_MRK_ID, DIALOG_STYLE_INPUT,
                    "Создание маркера (Шаг 2/3)", "Введите пользовательский ID маркера:", "Далее", "Отмена");
            }
            CreationTemp[playerid][tmp_CustomID] = cid;
            ShowPosChoice(playerid, DLG_MRK_POSCHOICE, "Создание маркера (Шаг 3/3)");
            return 1;
        }

        case DLG_MRK_POSCHOICE:
        {
            if(!response) return 1;
            if(listitem == 0)
            {
                new Float:x, Float:y, Float:z;
                GetPlayerPos(playerid, x, y, z);
                CreationTemp[playerid][tmp_X] = x;
                CreationTemp[playerid][tmp_Y] = y;
                CreationTemp[playerid][tmp_Z] = z;
                ShowMarkerConfirm(playerid);
            }
            else
            {
                ShowPlayerDialog(playerid, DLG_MRK_POSMANUAL, DIALOG_STYLE_INPUT,
                    "Координаты", "Введите координаты в формате X,Y,Z:", "Далее", "Отмена");
            }
            return 1;
        }

        case DLG_MRK_POSMANUAL:
        {
            if(!response) return 1;
            new Float:x, Float:y, Float:z;
            if(!ParseCoords(inputtext, x, y, z))
            {
                SendClientMessage(playerid, 0xFF3333AA, "Неверный формат. Пример: 1500.5,-1200.3,25.0");
                return ShowPlayerDialog(playerid, DLG_MRK_POSMANUAL, DIALOG_STYLE_INPUT,
                    "Координаты", "Введите координаты в формате X,Y,Z:", "Далее", "Отмена");
            }
            CreationTemp[playerid][tmp_X] = x;
            CreationTemp[playerid][tmp_Y] = y;
            CreationTemp[playerid][tmp_Z] = z;
            ShowMarkerConfirm(playerid);
            return 1;
        }

        case DLG_MRK_CONFIRM:
        {
            if(response) CreatePlacedMarker(playerid);
            else { ResetTemp(playerid); SendClientMessage(playerid, 0xFFFF00AA, "Создание отменено."); }
            return 1;
        }

        // ---------- TEXT (НАДПИСЬ) WIZARD ----------
        case DLG_TXT_TEXT:
        {
            if(!response) return 1;
            utf8_to_cp1251(inputtext); // вход из диалога приходит в UTF-8 — переводим в cp1251
            if(strlen(inputtext) == 0 || strlen(inputtext) > 128)
            {
                SendClientMessage(playerid, 0xFF3333AA, "Текст должен быть от 1 до 128 символов.");
                return StartTextWizard(playerid);
            }
            format(CreationTemp[playerid][tmp_SignText], 144, "%s", inputtext);

            new str[128];
            format(str, sizeof(str), "%s\n%s\n%s\n%s\n%s\n%s",
                g_SignColorNames[0], g_SignColorNames[1], g_SignColorNames[2],
                g_SignColorNames[3], g_SignColorNames[4], g_SignColorNames[5]);
            ShowPlayerDialog(playerid, DLG_TXT_COLOR, DIALOG_STYLE_LIST,
                "Создание надписи (Шаг 2/3) - Цвет", str, "Выбрать", "Назад");
            return 1;
        }

        case DLG_TXT_COLOR:
        {
            if(!response) return StartTextWizard(playerid);
            CreationTemp[playerid][tmp_Color] = listitem;
            ShowPosChoice(playerid, DLG_TXT_POSCHOICE, "Создание надписи (Шаг 3/3)");
            return 1;
        }

        case DLG_TXT_POSCHOICE:
        {
            if(!response) return 1;
            if(listitem == 0)
            {
                new Float:x, Float:y, Float:z;
                GetPlayerPos(playerid, x, y, z);
                CreationTemp[playerid][tmp_X] = x;
                CreationTemp[playerid][tmp_Y] = y;
                CreationTemp[playerid][tmp_Z] = z;
                ShowTextConfirm(playerid);
            }
            else
            {
                ShowPlayerDialog(playerid, DLG_TXT_POSMANUAL, DIALOG_STYLE_INPUT,
                    "Координаты", "Введите координаты в формате X,Y,Z:", "Далее", "Отмена");
            }
            return 1;
        }

        case DLG_TXT_POSMANUAL:
        {
            if(!response) return 1;
            new Float:x, Float:y, Float:z;
            if(!ParseCoords(inputtext, x, y, z))
            {
                SendClientMessage(playerid, 0xFF3333AA, "Неверный формат. Пример: 1500.5,-1200.3,25.0");
                return ShowPlayerDialog(playerid, DLG_TXT_POSMANUAL, DIALOG_STYLE_INPUT,
                    "Координаты", "Введите координаты в формате X,Y,Z:", "Далее", "Отмена");
            }
            CreationTemp[playerid][tmp_X] = x;
            CreationTemp[playerid][tmp_Y] = y;
            CreationTemp[playerid][tmp_Z] = z;
            ShowTextConfirm(playerid);
            return 1;
        }

        case DLG_TXT_CONFIRM:
        {
            if(response) CreatePlacedText(playerid);
            else { ResetTemp(playerid); SendClientMessage(playerid, 0xFFFF00AA, "Создание отменено."); }
            return 1;
        }

        // ---------- СПИСОК / УДАЛЕНИЕ ----------
        case DLG_LIST_EMPTY_INFO:
        {
            // просто закрываем сообщение "список пуст" - ничего не переоткрываем,
            // иначе получится бесконечный цикл (см. комментарий в ShowObjectsList)
            return 1;
        }

        case DLG_LIST_OBJECTS:
        {
            if(!response) return ShowMainMenu(playerid);
            new realindex = GetRealIndexFromListRow(listitem);
            if(realindex == -1)
            {
                SendClientMessage(playerid, 0xFF3333AA, "Некорректный выбор.");
                return 1;
            }
            ShowObjectActions(playerid, realindex);
            return 1;
        }

        case DLG_OBJECT_ACTIONS:
        {
            if(!response) return ShowObjectsList(playerid);
            new realindex = CreationTemp[playerid][tmp_ListIndex];
            new realitem = listitem - CreationTemp[playerid][tmp_MenuOffset];
            switch(realitem)
            {
                case 0: // телепорт
                {
                    SetPlayerPos(playerid, PlacedObjects[realindex][pl_X], PlacedObjects[realindex][pl_Y],
                        PlacedObjects[realindex][pl_Z] + 1.0);
                    SendClientMessage(playerid, 0x33FF33AA, "Вы телепортированы к объекту.");
                }
                case 1: // переместить
                {
                    StartMoveWizard(playerid, realindex);
                }
                case 2: // удалить
                {
                    ShowPlayerDialog(playerid, DLG_DELETE_CONFIRM, DIALOG_STYLE_MSGBOX,
                        "Подтверждение удаления",
                        "Вы уверены, что хотите удалить этот объект?\nЭто действие необратимо.",
                        "Удалить", "Отмена");
                }
            }
            return 1;
        }

        case DLG_DELETE_CONFIRM:
        {
            if(response)
            {
                DeletePlacedObject(CreationTemp[playerid][tmp_ListIndex]);
                SendClientMessage(playerid, 0x33FF33AA, "Объект удалён.");
            }
            ShowObjectsList(playerid);
            return 1;
        }

        // ---------- ПЕРЕМЕЩЕНИЕ (ТАЧ-НЮДЖЕР) ----------
        case DLG_MOVE_MENU:
        {
            if(!response) { CancelMove(playerid); return ShowObjectsList(playerid); }

            new Float:step = CreationTemp[playerid][tmp_MoveStep];
            new realitem = listitem - CreationTemp[playerid][tmp_MenuOffset];
            switch(realitem)
            {
                case 0: // сменить шаг
                {
                    ShowPlayerDialog(playerid, DLG_MOVE_STEP, DIALOG_STYLE_LIST, "Выберите шаг",
                        "0.1 м\n0.5 м\n1.0 м\n5.0 м\n10.0 м", "Выбрать", "Назад");
                    return 1;
                }
                case 1: { CreationTemp[playerid][tmp_X] += step; } // X+
                case 2: { CreationTemp[playerid][tmp_X] -= step; } // X-
                case 3: { CreationTemp[playerid][tmp_Y] += step; } // Y+
                case 4: { CreationTemp[playerid][tmp_Y] -= step; } // Y-
                case 5: { CreationTemp[playerid][tmp_Z] += step; } // Z+
                case 6: { CreationTemp[playerid][tmp_Z] -= step; } // Z-
                case 7: // сохранить
                {
                    SaveMovedPosition(playerid);
                    return ShowObjectsList(playerid);
                }
                case 8: // отмена
                {
                    CancelMove(playerid);
                    return ShowObjectsList(playerid);
                }
            }
            ApplyLivePreview(playerid);
            ShowMoveMenu(playerid);
            return 1;
        }

        case DLG_MOVE_STEP:
        {
            if(!response) { ShowMoveMenu(playerid); return 1; }
            new Float:steps[5] = {0.1, 0.5, 1.0, 5.0, 10.0};
            CreationTemp[playerid][tmp_MoveStep] = steps[listitem];
            ShowMoveMenu(playerid);
            return 1;
        }

        // ---------- ИЗБРАННОЕ ----------
        case DLG_FAV_LIST:
        {
            if(!response) return ShowMainMenu(playerid);
            if(listitem == 0) { StartFavoriteWizard(playerid); return 1; }

            new favindex = GetRealFavoriteIndexFromRow(listitem - 1);
            if(favindex == -1)
            {
                SendClientMessage(playerid, 0xFF3333AA, "Некорректный выбор.");
                return 1;
            }
            ShowFavoriteActions(playerid, favindex);
            return 1;
        }

        case DLG_FAV_TYPE_CHOICE:
        {
            if(!response) return ShowFavoritesList(playerid);
            switch(listitem)
            {
                case 0:
                {
                    CreationTemp[playerid][tmp_Type] = TYPE_NPC;
                    ShowPlayerDialog(playerid, DLG_FAV_NPC_SKIN, DIALOG_STYLE_INPUT,
                        "NPC - модель (шаг 1/3)", "Введите ID скина NPC (число, например 0-311):", "Далее", "Отмена");
                }
                case 1:
                {
                    CreationTemp[playerid][tmp_Type] = TYPE_OBJECT;
                    ShowPlayerDialog(playerid, DLG_FAV_OBJ_MODEL, DIALOG_STYLE_INPUT,
                        "Объект - модель (шаг 1/2)", "Введите ID модели объекта:", "Далее", "Отмена");
                }
                case 2:
                {
                    CreationTemp[playerid][tmp_Type] = TYPE_MARKER;
                    ShowPlayerDialog(playerid, DLG_FAV_MRK_ICON, DIALOG_STYLE_INPUT,
                        "Маркер - иконка (шаг 1/3)", "Введите ID иконки маркера (число, например 0-63):", "Далее", "Отмена");
                }
                case 3:
                {
                    CreationTemp[playerid][tmp_Type] = TYPE_TEXT;
                    ShowPlayerDialog(playerid, DLG_FAV_TXT_TEXT, DIALOG_STYLE_INPUT,
                        "Надпись - текст (шаг 1/3)", "Введите текст надписи:", "Далее", "Отмена");
                }
            }
            return 1;
        }

        case DLG_FAV_NPC_SKIN:
        {
            if(!response) return ShowFavoritesList(playerid);
            new modelid;
            if(sscanf(inputtext, "d", modelid) || modelid < 0 || modelid > 311)
            {
                SendClientMessage(playerid, 0xFF3333AA, "Некорректный ID скина (0-311).");
                return ShowPlayerDialog(playerid, DLG_FAV_NPC_SKIN, DIALOG_STYLE_INPUT,
                    "NPC - модель (шаг 1/3)", "Введите ID скина NPC (число, например 0-311):", "Далее", "Отмена");
            }
            CreationTemp[playerid][tmp_ModelID] = modelid;
            ShowPlayerDialog(playerid, DLG_FAV_NPC_NAME, DIALOG_STYLE_INPUT,
                "NPC - ник (шаг 2/3)", "Введите ник/название NPC:", "Далее", "Назад");
            return 1;
        }

        case DLG_FAV_NPC_NAME:
        {
            if(!response) return ShowPlayerDialog(playerid, DLG_FAV_NPC_SKIN, DIALOG_STYLE_INPUT,
                "NPC - модель (шаг 1/3)", "Введите ID скина NPC (число, например 0-311):", "Далее", "Отмена");
            utf8_to_cp1251(inputtext); // вход из диалога приходит в UTF-8 — переводим в cp1251
            if(strlen(inputtext) == 0 || strlen(inputtext) > 63)
            {
                SendClientMessage(playerid, 0xFF3333AA, "Название должно быть от 1 до 63 символов.");
                return ShowPlayerDialog(playerid, DLG_FAV_NPC_NAME, DIALOG_STYLE_INPUT,
                    "NPC - ник (шаг 2/3)", "Введите ник/название NPC:", "Далее", "Назад");
            }
            format(CreationTemp[playerid][tmp_Name], 64, "%s", inputtext);
            ShowPlayerDialog(playerid, DLG_FAV_LABEL, DIALOG_STYLE_INPUT,
                "Название в избранном (шаг 3/3)", "Введите короткое название для списка избранного:", "Сохранить", "Назад");
            return 1;
        }

        case DLG_FAV_OBJ_MODEL:
        {
            if(!response) return ShowFavoritesList(playerid);
            new modelid;
            if(sscanf(inputtext, "d", modelid) || modelid <= 0)
            {
                SendClientMessage(playerid, 0xFF3333AA, "Некорректный ID модели.");
                return ShowPlayerDialog(playerid, DLG_FAV_OBJ_MODEL, DIALOG_STYLE_INPUT,
                    "Объект - модель (шаг 1/2)", "Введите ID модели объекта:", "Далее", "Отмена");
            }
            CreationTemp[playerid][tmp_ModelID] = modelid;
            ShowPlayerDialog(playerid, DLG_FAV_LABEL, DIALOG_STYLE_INPUT,
                "Название в избранном (шаг 2/2)", "Введите короткое название для списка избранного:", "Сохранить", "Назад");
            return 1;
        }

        case DLG_FAV_MRK_ICON:
        {
            if(!response) return ShowFavoritesList(playerid);
            new iconid;
            if(sscanf(inputtext, "d", iconid) || iconid < 0 || iconid > 63)
            {
                SendClientMessage(playerid, 0xFF3333AA, "Некорректный ID иконки (0-63).");
                return ShowPlayerDialog(playerid, DLG_FAV_MRK_ICON, DIALOG_STYLE_INPUT,
                    "Маркер - иконка (шаг 1/3)", "Введите ID иконки маркера (число, например 0-63):", "Далее", "Отмена");
            }
            CreationTemp[playerid][tmp_ModelID] = iconid;
            ShowPlayerDialog(playerid, DLG_FAV_MRK_ID, DIALOG_STYLE_INPUT,
                "Маркер - ID (шаг 2/3)", "Введите кастомный ID маркера (число):", "Далее", "Назад");
            return 1;
        }

        case DLG_FAV_MRK_ID:
        {
            if(!response) return ShowPlayerDialog(playerid, DLG_FAV_MRK_ICON, DIALOG_STYLE_INPUT,
                "Маркер - иконка (шаг 1/3)", "Введите ID иконки маркера (число, например 0-63):", "Далее", "Отмена");
            new cid;
            if(sscanf(inputtext, "d", cid))
            {
                SendClientMessage(playerid, 0xFF3333AA, "Введите целое число.");
                return ShowPlayerDialog(playerid, DLG_FAV_MRK_ID, DIALOG_STYLE_INPUT,
                    "Маркер - ID (шаг 2/3)", "Введите кастомный ID маркера (число):", "Далее", "Назад");
            }
            CreationTemp[playerid][tmp_CustomID] = cid;
            ShowPlayerDialog(playerid, DLG_FAV_LABEL, DIALOG_STYLE_INPUT,
                "Название в избранном (шаг 3/3)", "Введите короткое название для списка избранного:", "Сохранить", "Назад");
            return 1;
        }

        case DLG_FAV_TXT_TEXT:
        {
            if(!response) return ShowFavoritesList(playerid);
            utf8_to_cp1251(inputtext); // вход из диалога приходит в UTF-8 — переводим в cp1251
            if(strlen(inputtext) == 0 || strlen(inputtext) > 143)
            {
                SendClientMessage(playerid, 0xFF3333AA, "Текст должен быть от 1 до 143 символов.");
                return ShowPlayerDialog(playerid, DLG_FAV_TXT_TEXT, DIALOG_STYLE_INPUT,
                    "Надпись - текст (шаг 1/3)", "Введите текст надписи:", "Далее", "Отмена");
            }
            format(CreationTemp[playerid][tmp_SignText], 144, "%s", inputtext);
            ShowPlayerDialog(playerid, DLG_FAV_TXT_COLOR, DIALOG_STYLE_LIST, "Надпись - цвет (шаг 2/3)",
                "{FFFFFF}Белый\n{FF3333}Красный\n{33FF33}Зелёный\n{3399FF}Синий\n{FFFF33}Жёлтый\n{FF9900}Оранжевый",
                "Далее", "Назад");
            return 1;
        }

        case DLG_FAV_TXT_COLOR:
        {
            if(!response) return ShowPlayerDialog(playerid, DLG_FAV_TXT_TEXT, DIALOG_STYLE_INPUT,
                "Надпись - текст (шаг 1/3)", "Введите текст надписи:", "Далее", "Отмена");
            CreationTemp[playerid][tmp_Color] = g_SignColors[listitem];
            ShowPlayerDialog(playerid, DLG_FAV_LABEL, DIALOG_STYLE_INPUT,
                "Название в избранном (шаг 3/3)", "Введите короткое название для списка избранного:", "Сохранить", "Назад");
            return 1;
        }

        case DLG_FAV_LABEL:
        {
            if(!response) return ShowFavoritesList(playerid);
            utf8_to_cp1251(inputtext); // вход из диалога приходит в UTF-8 — переводим в cp1251
            if(strlen(inputtext) == 0 || strlen(inputtext) > 31)
            {
                SendClientMessage(playerid, 0xFF3333AA, "Название должно быть от 1 до 31 символа.");
                return ShowPlayerDialog(playerid, DLG_FAV_LABEL, DIALOG_STYLE_INPUT,
                    "Название в избранном", "Введите короткое название для списка избранного:", "Сохранить", "Назад");
            }
            format(CreationTemp[playerid][tmp_FavLabel], 32, "%s", inputtext);
            CreateFavoriteFromTemp(playerid);
            return 1;
        }

        case DLG_FAV_ACTIONS:
        {
            if(!response) return ShowFavoritesList(playerid);
            new favindex = CreationTemp[playerid][tmp_FavIndex];
            new realitem = listitem - CreationTemp[playerid][tmp_MenuOffset];
            switch(realitem)
            {
                case 0: { PlaceFavoriteHere(playerid, favindex); }
                case 1:
                {
                    ShowPlayerDialog(playerid, DLG_FAV_RENAME, DIALOG_STYLE_INPUT,
                        "Переименовать", "Введите новое короткое название:", "Сохранить", "Назад");
                }
                case 2:
                {
                    ShowPlayerDialog(playerid, DLG_FAV_DELETE_CONFIRM, DIALOG_STYLE_MSGBOX,
                        "Подтверждение удаления",
                        "Удалить этот пресет из избранного?\nЭто не затронет уже размещённые объекты.",
                        "Удалить", "Отмена");
                }
            }
            return 1;
        }

        case DLG_FAV_RENAME:
        {
            new favindex = CreationTemp[playerid][tmp_FavIndex];
            if(!response) return ShowFavoriteActions(playerid, favindex);
            utf8_to_cp1251(inputtext); // вход из диалога приходит в UTF-8 — переводим в cp1251
            if(strlen(inputtext) == 0 || strlen(inputtext) > 31)
            {
                SendClientMessage(playerid, 0xFF3333AA, "Название должно быть от 1 до 31 символа.");
                return ShowPlayerDialog(playerid, DLG_FAV_RENAME, DIALOG_STYLE_INPUT,
                    "Переименовать", "Введите новое короткое название:", "Сохранить", "Назад");
            }
            format(Favorites[favindex][fav_Label], 32, "%s", inputtext);
            ObjectPlacer_Favorites_Rename(favindex, inputtext);
            SendClientMessage(playerid, 0x33FF33AA, "Переименовано.");
            ShowFavoritesList(playerid);
            return 1;
        }

        case DLG_FAV_DELETE_CONFIRM:
        {
            new favindex = CreationTemp[playerid][tmp_FavIndex];
            if(!response) return ShowFavoriteActions(playerid, favindex);
            ObjectPlacer_Favorites_Delete(favindex);
            Favorites[favindex][fav_Used] = false;
            Favorites[favindex][fav_SQLID] = 0;
            g_TotalFavorites--;
            SendClientMessage(playerid, 0x33FF33AA, "Удалено из избранного.");
            ShowFavoritesList(playerid);
            return 1;
        }
    }
    return 0;
}

// ================= ДОГРУЗКА МАРКЕРОВ ПРИ ВХОДЕ ИГРОКА =================
ObjectPlacer_OnPlayerConnect(playerid)
{
    for(new i = 0; i < MAX_PLACED_OBJECTS; i++)
    {
        if(PlacedObjects[i][pl_Used] && PlacedObjects[i][pl_Type] == TYPE_MARKER)
        {
            SetPlayerMapIcon(playerid, PlacedObjects[i][pl_IconSlot],
                PlacedObjects[i][pl_X], PlacedObjects[i][pl_Y], PlacedObjects[i][pl_Z],
                PlacedObjects[i][pl_ModelID], 0, MAPICON_LOCAL);
        }
    }
    return 1;
}

// ================= ИЗБРАННОЕ =================
// Отдельная от размещённых объектов библиотека пресетов: админ один раз
// сохраняет шаблон (модель/ник/текст/цвет + короткое название), а потом
// в один клик "Установить здесь" создаёт из него реальный объект в игре -
// без повторного набора модели/текста каждый раз. Хранится в отдельной
// таблице objects_favorites, не путать со списком уже размещённых объектов.

FindFreeFavoriteSlot()
{
    for(new i = 0; i < MAX_FAVORITES; i++)
        if(!Favorites[i][fav_Used]) return i;
    return -1;
}

// индекс-мэппинг строки списка избранного (строка 0 - это "+Добавить новое",
// поэтому реальные пресеты начинаются с row=1) -> реальный индекс в Favorites
GetRealFavoriteIndexFromRow(row)
{
    new count = -1;
    for(new i = 0; i < MAX_FAVORITES; i++)
    {
        if(!Favorites[i][fav_Used]) continue;
        count++;
        if(count == row) return i;
    }
    return -1;
}

FavoriteTypeName(E_OBJ_TYPE:type)
{
    new name[16];
    switch(type)
    {
        case TYPE_NPC:    { name = "NPC"; }
        case TYPE_OBJECT: { name = "Объект"; }
        case TYPE_MARKER: { name = "Маркер"; }
        case TYPE_TEXT:   { name = "Надпись"; }
    }
    return name;
}

// ---------------- СПИСОК ИЗБРАННОГО ----------------
ShowFavoritesList(playerid)
{
    new str[2048];
    str[0] = 0;
    strcat(str, "{33FF33}+ Добавить новое\n");

    for(new i = 0; i < MAX_FAVORITES; i++)
    {
        if(!Favorites[i][fav_Used]) continue;

        new favline[100];
        format(favline, sizeof(favline), "{FFFFFF}%s ({ADD8E6}%s{FFFFFF})\n", Favorites[i][fav_Label], FavoriteTypeName(Favorites[i][fav_Type]));
        strcat(str, favline);
    }

    ShowPlayerDialog(playerid, DLG_FAV_LIST, DIALOG_STYLE_LIST, "Избранное", str, "Выбрать", "Назад");
}

// ---------------- МАСТЕР ДОБАВЛЕНИЯ НОВОГО ИЗБРАННОГО ----------------
StartFavoriteWizard(playerid)
{
    if(g_TotalFavorites >= MAX_FAVORITES)
        return SendClientMessage(playerid, 0xFF3333AA, "Достигнут лимит избранного.");

    ShowPlayerDialog(playerid, DLG_FAV_TYPE_CHOICE, DIALOG_STYLE_LIST,
        "Тип избранного",
        "{FFFFFF}NPC\n{FFFFFF}Объект\n{FFFFFF}Маркер\n{FFFFFF}Надпись",
        "Далее", "Отмена");
}

// сохраняет новый пресет из CreationTemp (заполняется мастером выше)
CreateFavoriteFromTemp(playerid)
{
    new slot = FindFreeFavoriteSlot();
    if(slot == -1)
    {
        SendClientMessage(playerid, 0xFF3333AA, "Достигнут лимит избранного.");
        return;
    }

    Favorites[slot][fav_Used]     = true;
    Favorites[slot][fav_Type]     = CreationTemp[playerid][tmp_Type];
    Favorites[slot][fav_ModelID]  = CreationTemp[playerid][tmp_ModelID];
    Favorites[slot][fav_CustomID] = CreationTemp[playerid][tmp_CustomID];
    Favorites[slot][fav_Color]    = CreationTemp[playerid][tmp_Color];
    format(Favorites[slot][fav_Name], 64, "%s", CreationTemp[playerid][tmp_Name]);
    format(Favorites[slot][fav_SignText], 144, "%s", CreationTemp[playerid][tmp_SignText]);
    format(Favorites[slot][fav_Label], 32, "%s", CreationTemp[playerid][tmp_FavLabel]);
    GetPlayerName(playerid, Favorites[slot][fav_CreatedBy], MAX_PLAYER_NAME);

    g_TotalFavorites++;
    ObjectPlacer_Favorites_Persist(slot);

    SendClientMessage(playerid, 0x33FF33AA, "Добавлено в избранное.");
    ShowFavoritesList(playerid);
}

// ---------------- ДЕЙСТВИЯ С ИЗБРАННЫМ ----------------
ShowFavoriteActions(playerid, favindex)
{
    CreationTemp[playerid][tmp_FavIndex] = favindex;

    new header[150];
    format(header, sizeof(header), "{ADD8E6}Название:{FFFFFF} %s\n{ADD8E6}Тип:{FFFFFF} %s\n",
        Favorites[favindex][fav_Label], FavoriteTypeName(Favorites[favindex][fav_Type]));
    CreationTemp[playerid][tmp_MenuOffset] = CountLines(header);

    new str[300];
    format(str, sizeof(str),
        "%s{33FF33}Установить здесь\n"\
        "{FFFFFF}Переименовать\n"\
        "{FF3333}Удалить из избранного", header);

    ShowPlayerDialog(playerid, DLG_FAV_ACTIONS, DIALOG_STYLE_LIST, "Действия с избранным", str, "Выбрать", "Назад");
}

// создаёт реальный размещённый объект из пресета избранного в текущей
// позиции админа (и с его текущим углом поворота для NPC)
PlaceFavoriteHere(playerid, favindex)
{
    new slot = FindFreeSlot();
    if(slot == -1)
    {
        SendClientMessage(playerid, 0xFF3333AA, "Достигнут лимит размещённых объектов.");
        return;
    }

    new Float:x, Float:y, Float:z;
    GetPlayerPos(playerid, x, y, z);

    PlacedObjects[slot][pl_Used]     = true;
    PlacedObjects[slot][pl_Type]     = Favorites[favindex][fav_Type];
    PlacedObjects[slot][pl_ModelID]  = Favorites[favindex][fav_ModelID];
    PlacedObjects[slot][pl_CustomID] = Favorites[favindex][fav_CustomID];
    PlacedObjects[slot][pl_Color]    = Favorites[favindex][fav_Color];
    PlacedObjects[slot][pl_X] = x;
    PlacedObjects[slot][pl_Y] = y;
    PlacedObjects[slot][pl_Z] = z;
    format(PlacedObjects[slot][pl_Name], 64, "%s", Favorites[favindex][fav_Name]);
    format(PlacedObjects[slot][pl_SignText], 144, "%s", Favorites[favindex][fav_SignText]);
    GetPlayerName(playerid, PlacedObjects[slot][pl_CreatedBy], MAX_PLAYER_NAME);
    GetPlayerFacingAngle(playerid, PlacedObjects[slot][pl_Angle]);

    switch(PlacedObjects[slot][pl_Type])
    {
        case TYPE_NPC:    { SpawnNPCVisual(slot); }
        case TYPE_OBJECT: { SpawnObjectVisual(slot); }
        case TYPE_TEXT:   { SpawnTextVisual(slot); }
        case TYPE_MARKER:
        {
            PlacedObjects[slot][pl_IconSlot] = g_NextIconSlot;
            g_NextIconSlot = (g_NextIconSlot + 1) % MAX_ICON_SLOTS;
            for(new i = 0; i < MAX_PLAYERS; i++)
            {
                if(IsPlayerConnected(i))
                {
                    SetPlayerMapIcon(i, PlacedObjects[slot][pl_IconSlot], x, y, z,
                        PlacedObjects[slot][pl_ModelID], 0, MAPICON_LOCAL);
                }
            }
        }
    }

    g_TotalObjects++;
    ObjectPlacer_Persist(slot);
    SendClientMessage(playerid, 0x33FF33AA, "Объект создан из избранного.");
}

// ---------------- СОХРАНЕНИЕ / ЗАГРУЗКА ИЗБРАННОГО В БД ----------------
ObjectPlacer_Favorites_Persist(slot)
{
    new query[768];
    mysql_format(mysql, query, sizeof query,
        "INSERT INTO objects_favorites (type, model_id, custom_id, name, sign_text, color, label, created_by) \
         VALUES (%d, %d, %d, '%e', '%e', %d, '%e', '%e')",
        _:Favorites[slot][fav_Type], Favorites[slot][fav_ModelID], Favorites[slot][fav_CustomID],
        Favorites[slot][fav_Name], Favorites[slot][fav_SignText], Favorites[slot][fav_Color],
        Favorites[slot][fav_Label], Favorites[slot][fav_CreatedBy]);
    mysql_tquery(mysql, query, "OnFavoriteInserted", "i", slot);
}

forward OnFavoriteInserted(slot);
public OnFavoriteInserted(slot)
{
    if(Favorites[slot][fav_Used])
        Favorites[slot][fav_SQLID] = cache_insert_id();
    return 1;
}

ObjectPlacer_Favorites_Rename(favindex, const newlabel[])
{
    if(Favorites[favindex][fav_SQLID] <= 0) return 0;

    new query[160];
    mysql_format(mysql, query, sizeof query,
        "UPDATE objects_favorites SET label='%e' WHERE id=%d LIMIT 1",
        newlabel, Favorites[favindex][fav_SQLID]);
    mysql_tquery(mysql, query);
    return 1;
}

ObjectPlacer_Favorites_Delete(favindex)
{
    if(Favorites[favindex][fav_SQLID] <= 0) return 0;

    new query[96];
    mysql_format(mysql, query, sizeof query,
        "DELETE FROM objects_favorites WHERE id=%d LIMIT 1", Favorites[favindex][fav_SQLID]);
    mysql_tquery(mysql, query);
    return 1;
}

// вызывается один раз из OnGameModeInit - поднимает всё избранное после рестарта
ObjectPlacer_Favorites_LoadFromDB()
{
    mysql_tquery(mysql, "SELECT * FROM objects_favorites", "OnFavoritesLoaded", "");
}

forward OnFavoritesLoaded();
public OnFavoritesLoaded()
{
    new rows = cache_num_rows();
    for(new i = 0; i < rows; i++)
    {
        new slot = FindFreeFavoriteSlot();
        if(slot == -1)
        {
            printf("[object_placer] Достигнут лимит MAX_FAVORITES при загрузке из БД.");
            break;
        }

        new type_val = cache_get_field_content_int(i, "type");

        Favorites[slot][fav_Used]     = true;
        Favorites[slot][fav_Type]     = E_OBJ_TYPE:type_val;
        Favorites[slot][fav_ModelID]  = cache_get_field_content_int(i, "model_id");
        Favorites[slot][fav_CustomID] = cache_get_field_content_int(i, "custom_id");
        Favorites[slot][fav_Color]    = cache_get_field_content_int(i, "color");
        Favorites[slot][fav_SQLID]    = cache_get_field_content_int(i, "id");

        cache_get_field_content(i, "name", Favorites[slot][fav_Name]);
        cache_get_field_content(i, "sign_text", Favorites[slot][fav_SignText]);
        cache_get_field_content(i, "label", Favorites[slot][fav_Label]);
        cache_get_field_content(i, "created_by", Favorites[slot][fav_CreatedBy]);

        g_TotalFavorites++;
    }

    printf("[object_placer] Загружено избранного из БД: %d", g_TotalFavorites);
    return 1;
}

/*
    ============================================================
    ИДЕИ ДЛЯ РАЗВИТИЯ (от меня):
    ============================================================
    1. ПЕРСИСТЕНТНОСТЬ: уже реализована (таблица `objects_placed`,
       ObjectPlacer_LoadFromDB вызывается из OnGameModeInit).

    2. STREAMER PLUGIN: замени CreateObject/CreateActor на
       CreateDynamicObject/CreateDynamicActor из Incognito Streamer —
       снимает лимиты SA-MP (макс. объектов/акторов) и добавляет
       область видимости (streamdistance), что важно для больших карт.

    3. УРОВНИ ДОСТУПА: например, обычные админы могут только смотреть
       список и телепортироваться, а удалять/создавать — только
       старшие админы.

    4. РЕДАКТИРОВАНИЕ: добавь пункт "Переместить" в DLG_OBJECT_ACTIONS,
       используя EditObject/EditPlayerObject для NPC и объектов —
       перетаскивание мышкой прямо в игре вместо ввода координат.

    5. ПОИСК И ФИЛЬТРЫ: в списке объектов добавь фильтр по типу
       (только NPC / только объекты / только маркеры) и поиск по
       кастомному ID, если список станет большим.

    6. ЛОГИРОВАНИЕ: пиши в файл лог всех созданий/удалений с указанием
       ника админа, времени и координат — полезно для расследований
       злоупотреблений.

    7. ПРОВЕРКА НА ДУБЛИКАТЫ: перед созданием проверяй, нет ли уже
       объекта с таким же CustomID, чтобы не путать их в других
       скриптах (например, при переходе к NPC по ID из квестовой
       системы).

    8. ПРИВЯЗКА ФУНКЦИОНАЛА К NPC: сейчас NPC — это просто актор с
       именем. Через кастомный ID можно повесить на него диалог
       торговца, квеста и т.п. в OnPlayerGiveDamageActor /
       OnPlayerClickActor — так как ID уже под рукой, интеграция
       простая.
    ============================================================
*/
