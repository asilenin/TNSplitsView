import Toybox.Application;
import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.Activity;
import Toybox.Lang;
import Toybox.System;
using Toybox.FitContributor;

// TSV-35: у шести моделей с 32 КБ нет тача. Исключение недоступного ввода
// освобождает память для истории; на сенсорных часах код и поведение сохранены.

function rowsForMode(m) {            // 0=min,1=med,2=max
    if (m == 2) { return 1; }
    if (m == 1) { return 5; }       // MID — карусель 5 строк, центр активный
    return 6;                       // MIN — шесть одинаковых карточек (TSV-34/35)
}

// палитра цветов по индексу (0..6); light — светлая тема (TSV-18): на белом фоне жёлтый и оранжевый
// затемнены, «белый» зоны — чёрный (иначе пропал бы)
function paletteColor(idx, light) {
    if (light) {
        if (idx == 0) { return 0x000000; }   // «белый» → чёрный
        if (idx == 1) { return 0x0086C8; }   // голубой
        if (idx == 2) { return 0x008A00; }   // зелёный
        if (idx == 3) { return 0xB08A00; }   // жёлтый (самый слабый по контрасту на белом)
        if (idx == 4) { return 0xD95F00; }   // оранжевый
        if (idx == 5) { return 0xD00000; }   // красный
        return 0x8A2BE2;                     // 6 = фиолетовый
    }
    if (idx == 0) { return 0xFFFFFF; }   // белый
    if (idx == 1) { return 0x33CCFF; }   // голубой
    if (idx == 2) { return 0x00DD00; }   // зелёный
    if (idx == 3) { return 0xFFFF00; }   // жёлтый
    if (idx == 4) { return 0xFF8800; }   // оранжевый
    if (idx == 5) { return 0xFF0000; }   // красный
    return 0xAA44FF;                     // 6 = фиолетовый
}

// парсинг "mm:ss" -> секунды. Возвращает -1 при ошибке формата.
function parseMMSS(s) {
    if (s == null) { return -1; }
    var str = s.toString();
    var colon = str.find(":");
    if (colon == null) { return -1; }
    var mm = str.substring(0, colon);
    var ss = str.substring(colon + 1, str.length());
    if (mm.length() == 0 || ss.length() == 0) { return -1; }
    var m = mm.toNumber();
    var sec = ss.toNumber();
    if (m == null || sec == null) { return -1; }
    if (m < 0 || m > 59 || sec < 0 || sec > 59) { return -1; }
    return m * 60 + sec;
}

class SplitsApp extends Application.AppBase {
    var _view;
    function initialize() { AppBase.initialize(); }
    function getInitialView() {
        _view = new SplitsView();
        return [ _view, new SplitsDelegate(_view) ];
    }
    function onSettingsChanged() {
        if (_view != null) { _view.reloadSettings(); WatchUi.requestUpdate(); }
    }
}

class SplitsView extends WatchUi.DataField {
    // Запись списка: массив [type, t1, t2, t3, t4]
    //   type 0 = лап:    [0, lapNum, lapTimeSec, lapDistM, paceSec, tMsAbs]
    //   type 1 = лактат: [1, val10,  tMsAbs,     0,        0,       tMsAbs]
    // Для единообразия держим в каждом элементе абсолютный таймстамп в индексе [5].
    var _items;            // разнородный список, отсортирован по времени добавления
    var _lastTimeMs; var _lastDistM;
    var _topIndex; var _fontMode; var _w; var _h; var _tapFlash;
    var _lactateEnabled;
    var _listMode;         // 0=MIN,1=MID,2=MAX,3=Cycle tap,4=Cycle timer
    var _touchOn;          // тач есть физически И включён настройкой
    var _cycleSec;         // интервал автоцикла (сек)
    var _cycleAccum;       // накопитель секунд для автоцикла
    var _lapCount;         // номер последнего закрытого круга: ранние круги могут уйти из списка (addItem)
    const RESERVE = 1536;  // байт свободной памяти, которые список оставляет полю (addItem, TSV-25)

    // настройки порогов/цветов
    var _thr;              // массив 6 порогов в сек/км (канонический формат)
    var _col;              // массив 7 цветов (0xRRGGBB)
    var _settingsError;    // строка ошибки парсинга или null
    var _useMiles;         // системные единицы: true=мили

    // тема (TSV-18): цвета фона, основного и второстепенного текста, линий; шрифты — Golos Text (TSV-35)
    var _light;            // true = светлая тема (белый фон)
    var _bg; var _fg; var _dim; var _line;
    var _fRow; var _fKey; var _fBig;
    var _fonts as Array or Null;
    var _fontIds as Array or Null; var _fontPage = -1; var _lowMemory; var _cachedFont = -1;
    // Низ видимых цифр относительно начала строки, Golos Text на 454 (tools/make_fonts.py).
    var _digitBottom as Array = [16,20,20,24,36,40,48,63,71,16];

    // режим: 0 = список, 1 = ввод лактата
    var _mode;

    // ввод лактата
    var _val10; const MIN10 = 0; const MAX10 = 250;
    var _pending; var _holdSec; var _savedFlash;

    // FIT
    var _fieldRecord;      // числовое record-поле (field 1)
    var _fieldSession;     // итоговое session-поле (field 2): замер, не отстоявший своё в потоке record
    var _timerMs;          // timerTime прошлого compute: не изменился — таймер стоит

    function initialize() {
        DataField.initialize();
        _items = [];
        _lastTimeMs = 0; _lastDistM = 0.0;
        _topIndex = 0; _w = 0; _h = 0; _tapFlash = 0;
        _curLapTime = 0.0; _curLapDist = 0.0; _curLapPace = 0.0;
        _mode = 0;
        _fontMode = 0;
        _settingsError = null;
        _touchOn = true; _cycleSec = 5; _cycleAccum = 0;
        _val10 = 20; _pending = 0; _holdSec = 0; _savedFlash = 0;
        _timerMs = 0;
        _lapCount = 0;
        reloadSettings();

        if (_lactateEnabled) {
            _fieldRecord = createField(
                "lactate", 1, FitContributor.DATA_TYPE_FLOAT,
                { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "mmol/L" }
            );
            _fieldSession = createField(
                "lactate_stop", 2, FitContributor.DATA_TYPE_FLOAT,
                { :mesgType => FitContributor.MESG_TYPE_SESSION, :units => "mmol/L" }
            );
        }
    }

    function reloadSettings() {
        // есть ли тач физически
        var ds = System.getDeviceSettings();
        var hasTouch = (ds != null && ds.isTouchScreen);

        // настройка использования тача
        var ut = Application.Properties.getValue("useTouch");
        var wantTouch = (ut == null) ? true : ut;
        // тач активен только если он есть физически И включён настройкой
        _touchOn = hasTouch && wantTouch;

        // режим списка: 0=MIN,1=MID,2=MAX,3=Cycle by tap,4=Cycle by timer
        var lm = Application.Properties.getValue("listMode");
        _listMode = (lm == null) ? 3 : lm;
        if (_listMode <= 2) { _fontMode = _listMode; }   // фиксированный режим
        if (_fontMode == null) { _fontMode = 0; }
        // Cycle by tap без тача переключаться не сможет — но это не застревание:
        // список показывается, просто один режим. Описано в настройках.

        // интервал автоцикла
        var cs = Application.Properties.getValue("cycleSec");
        _cycleSec = (cs == null || cs < 1) ? 5 : cs;
        _cycleAccum = 0;

        // лактат: требует активного тача
        var le = Application.Properties.getValue("lactateEnabled");
        _lactateEnabled = ((le == null) ? false : le) && _touchOn;
        if (!_lactateEnabled && _mode == 1) { _mode = 0; }

        // системные единицы (для отображения списка)
        _useMiles = false;
        if (ds != null && ds.paceUnits == System.UNIT_STATUTE) { _useMiles = true; }

        // единицы ввода порогов
        var tu = Application.Properties.getValue("thresholdUnit");
        var inputMiles = (tu != null && tu == 1);

        // читаем 6 порогов mm:ss, парсим, конвертим в сек/км (канон)
        _settingsError = null;
        _thr = new [6];
        var keys = ["pace1","pace2","pace3","pace4","pace5","pace6"];
        for (var i = 0; i < 6; i += 1) {
            var raw = Application.Properties.getValue(keys[i]);
            var secs = parseMMSS(raw);
            if (secs < 0) {
                // ошибка формата — запомнить и показать экран
                var shown = (raw == null) ? "" : raw.toString();
                _settingsError = "Threshold " + (i+1).format("%d")
                    + " invalid: \"" + shown + "\"";
                _thr[i] = 9999;   // заглушка, экран всё равно покажет ошибку
            } else {
                // secs — сек на введённую единицу. Канон: сек/км.
                if (inputMiles) {
                    // сек/милю -> сек/км : делим на 1.609344
                    _thr[i] = (secs / 1.609344).toNumber();
                } else {
                    _thr[i] = secs;
                }
            }
        }

        // тема: 0 = тёмная (по умолчанию, как было), 1 = светлая с белым фоном
        var th = Application.Properties.getValue("theme");
        _light = (th != null && th == 1);
        if (_light) { _bg = 0xFFFFFF; _fg = 0x000000; _dim = 0x6A6A6A; _line = 0xC4C4C4; }
        else        { _bg = 0x000000; _fg = 0xDCDCDC; _dim = 0x7A7A7A; _line = 0x3A3A3A; }

        // цвета 7 зон
        _col = new [7];
        var ckeys = ["color1","color2","color3","color4","color5","color6","color7"];
        for (var j = 0; j < 7; j += 1) {
            var ci = Application.Properties.getValue(ckeys[j]);
            _col[j] = paletteColor((ci == null) ? 0 : ci, _light);
        }
    }

    // цвет по темпу (сек/км) на основе настроенных порогов/цветов
    function colorFor(paceSec) {
        if (paceSec <= 0) { return _fg; }
        for (var i = 0; i < 6; i += 1) {
            if (paceSec < _thr[i]) { return _col[i]; }
        }
        return _col[6];   // медленнее последнего порога — зона 7
    }

    // ——— список ———
    function nItems() { return _items.size() + 1; }   // +1 живой текущий круг (виртуальная строка в конце)

    // живые значения текущего круга (обновляются в compute)
    var _curLapTime = 0.0;   // сек
    var _curLapDist = 0.0;   // м
    var _curLapPace = 0.0;   // сек/км

    // вернуть запись по индексу: реальные лапы из _items, последний индекс — живой круг
    function itemAt(idx) {
        if (idx < _items.size()) { return _items[idx]; }
        // виртуальная живая строка: type 0, номер = следующий за последним закрытым, маркер времени -1
        return [ 0, _lapCount + 1, _curLapTime, _curLapDist, _curLapPace, -1 ];
    }

    function clampTop() {
        // Во всех плотностях индекс означает выбранную запись: переключение режима не сдвигает историю (TSV-32).
        if (_topIndex < 0) { _topIndex = 0; }
        if (_topIndex > nItems() - 1) { _topIndex = nItems() - 1; }
    }

    function onTimerLap() {
        var info = Activity.getActivityInfo();
        var tMs = 0; var dM = 0.0;
        if (info != null) {
            if (info.timerTime != null) { tMs = info.timerTime; }
            if (info.elapsedDistance != null) { dM = info.elapsedDistance; }
        }
        var lapTime = (tMs - _lastTimeMs) / 1000.0;
        var lapDist = dM - _lastDistM;
        var pace = 0.0;
        if (lapDist > 0) { pace = lapTime / (lapDist / 1000.0); }
        _lapCount += 1;
        addItem([ 0, _lapCount, lapTime, lapDist, pace, tMs ]);
        _lastTimeMs = tMs; _lastDistM = dM;
        // новый круг стартует с нуля
        _curLapTime = 0.0; _curLapDist = 0.0; _curLapPace = 0.0;
        _topIndex = nItems() + 10;
        clampTop();
        WatchUi.requestUpdate();
    }

    // TSV-25: часы с 32 КБ под поле (fēnix 6/6S, fr245, fr645, fr935, fr735xt) дают ему 28,4 КиБ, пустое поле занимает
    // около 25, запись круга — 61 байт, и в симуляторе поле падало при отрисовке на 38–52 кругах. Поэтому новая запись
    // вытесняет самые ранние (в файле тренировки они остаются), пока свободно меньше RESERVE: запас на пик отрисовки
    // (в симуляторе до 0,4 КиБ) и перечитывание настроек. Правило смотрит на память самих часов, а не на число кругов,
    // подобранное в симуляторе; на часах с 64 КБ и больше до вытеснения не доходит.
    function addItem(it) {
        _items.add(it);
        while (_items.size() > 1 && System.getSystemStats().freeMemory < RESERVE) { _items.remove(_items[0]); }
    }

    function compute(info) {
        // автоцикл режима по таймеру (listMode==4), раз в секунду
        if (_listMode == 4 && _mode == 0) {
            _cycleAccum += 1;
            if (_cycleAccum >= _cycleSec) {
                _cycleAccum = 0;
                _fontMode = (_fontMode + 1) % 3;
                clampTop();
                WatchUi.requestUpdate();
            }
        }
        // живые значения текущего круга = общее − накопленное на последней отсечке
        if (info != null) {
            var tMs = (info.timerTime != null) ? info.timerTime : _lastTimeMs;
            var dM  = (info.elapsedDistance != null) ? info.elapsedDistance : _lastDistM;
            _curLapTime = (tMs - _lastTimeMs) / 1000.0;
            _curLapDist = dM - _lastDistM;
            // темп считаем только когда набралось >10 м, иначе мусор на старте круга
            if (_curLapDist > 10.0) {
                _curLapPace = _curLapTime / (_curLapDist / 1000.0);
            } else {
                _curLapPace = 0.0;   // 0 => fmtPace покажет "--"
            }
            WatchUi.requestUpdate();   // тикаем живую строку каждую секунду
        }

        if (_fieldRecord == null) { return; }
        // Буфер _pending: по тапу OK туда кладётся значение замера, и держится
        // _holdSec секунд. Каждую секунду пишем _pending в плот. Значение держим
        // несколько секунд, потому что Garmin прореживает поток на длинных
        // тренировках (~1 запись в 3с) — одиночная точка выпала бы. Держим 10с,
        // чтобы значение гарантированно попало в сохранённые сэмплы.
        // TSV-31: часы пишут record-точки только при идущем таймере, поэтому 10 с держания
        // считаются, только пока растёт timerTime: замер после «Стоп» ляжет в поток после «Продолжить».
        // Если бегун сохранит тренировку, не продолжив, точек больше не будет — на этот случай замер
        // лежит и в итоговом session-поле, которое часы пишут при сохранении. Когда замер отстоял
        // 10 с в потоке, session-поле обнуляется: ненулевое значение в файле — замер, которого
        // в потоке нет или не хватило (сохранили раньше 10 с); его читать коннектору Runner MCP.
        var tMs = (info != null && info.timerTime != null) ? info.timerTime : _timerMs;
        var running = (tMs != _timerMs);
        _timerMs = tMs;
        _fieldRecord.setData(_pending / 10.0);
        if (_pending != 0) {
            _fieldSession.setData(_pending / 10.0);
            if (running) { _holdSec -= 1; }
            if (_holdSec <= 0) {
                _pending = 0;   // время держания вышло — дальше нули
                _fieldSession.setData(0.0);
            }
        }
    }

    function pageOlder() { _topIndex -= 1; clampTop(); }
    function pageNewer() { _topIndex += 1; clampTop(); }
    function onLayout(dc) {
        _w = dc.getWidth(); _h = dc.getHeight();
        _fontIds = [ Rez.Fonts.Tiny, Rez.Fonts.Row, Rez.Fonts.Number, Rez.Fonts.Near,
            Rez.Fonts.Dist, Rez.Fonts.Distmax, Rez.Fonts.Active, Rez.Fonts.Big,
            Rez.Fonts.Max, Rez.Fonts.Live, Rez.Fonts.Ok, Rez.Fonts.Key, Rez.Fonts.Error ];
        _lowMemory = System.getSystemStats().totalMemory <= 32768;
        resetFonts();
    }

    // TSV-35: без graphics pool (в том числе fēnix 6 с 32 КБ) все размеры сразу
    // не помещаются. При смене экрана отпускаем ресурсы; на 32 КБ держим только один
    // шрифт одновременно, а на остальных часах кэшируем размеры текущего экрана.
    function resetFonts() {
        _fRow=null; _fKey=null; _fBig=null;
        _fonts = new [13];
        _cachedFont=-1;
        _fontPage = _mode*3+_fontMode;
        if (_mode == 1) { _fRow=font(1); _fKey=font(11); _fBig=font(7); }
    }
    function font(f) {
        if (_lowMemory && f != _cachedFont) {
            if (_cachedFont >= 0) { _fonts[_cachedFont]=null; }
            _cachedFont=f;
        }
        if (_fonts[f] == null) { _fonts[f]=WatchUi.loadResource(_fontIds[f]); }
        return _fonts[f];
    }

    // круг от часа — часы и минуты без секунд («1h05»): «65:00» и «120:00» шире пяти знаков и в списке MIN доходили
    // до номера круга (TSV-29)
    function fmtTime(sec) {
        var s = sec.toNumber();
        if (s >= 3600) { return (s/3600).format("%d") + "h" + (s%3600/60).format("%02d"); }
        return (s/60).format("%d") + ":" + (s%60).format("%02d");
    }
    function fmtPace(p) {
        if (p <= 0) { return "--"; }
        var s = p.toNumber(); return (s/60).format("%d") + ":" + (s%60).format("%02d");
    }

    // темп (сек/км канон) в системных единицах: мин:сек на км или на милю
    function fmtPaceU(paceSecPerKm) {
        if (paceSecPerKm <= 0) { return "--"; }
        var p = paceSecPerKm;
        if (_useMiles) { p = paceSecPerKm * 1.609344; }  // сек/км -> сек/милю
        var s = p.toNumber();
        return (s/60).format("%d") + ":" + (s%60).format("%02d");
    }

    function distUnit() { return _useMiles ? "mi" : "km"; }
    function fmtClock(tMs) {
        var s = (tMs / 1000).toNumber();
        return (s/60).format("%d") + ":" + (s%60).format("%02d");
    }
    (:touchInput)
    function valStr() {
        return (_val10/10).format("%d") + "," + (_val10%10).format("%d");
    }
    // ——— ввод лактата ———
    (:touchInput)
    function bump(d10) {
        _val10 += d10;
        if (_val10 < MIN10) { _val10 = MIN10; }
        if (_val10 > MAX10) { _val10 = MAX10; }
        WatchUi.requestUpdate();
    }

    (:touchInput)
    function confirmLactate() {
        // время
        var info = Activity.getActivityInfo();
        var tMs = 0;
        if (info != null && info.timerTime != null) { tMs = info.timerTime; }
        // кладём значение в буфер; compute запишет его в плот и обнулит буфер
        _pending = _val10;
        _holdSec = 10;   // держать значение 10с, чтобы пережить прореживание потока
        // в список как отдельная строка
        addItem([ 1, _val10, tMs, 0, 0, tMs ]);
        _savedFlash = 4;
        // вернуться в список и показать свежую отметку
        _mode = 0;
        _topIndex = _items.size() - 1; // TSV-35: показать добавленный замер, как в принятом сценарии.
        clampTop();
        WatchUi.requestUpdate();
    }

    // ——— геометрия зон ввода (как в рабочем прототипе) ———
    // 3 колонки × 2 ряда, левый край — возврат
    (:touchInput)
    function inputZoneAt(x, y) {
        // возврат — левый край ТОЛЬКО в средней полосе по высоте (чтобы +1/-1 в углах работали)
        if (x < _w * 0.16 && y > _h * 0.38 && y < _h * 0.62) { return "back"; }
        var col = (x < _w/3) ? 0 : ((x < 2*_w/3) ? 1 : 2);
        var row = (y < _h/2) ? 0 : 1;
        if (row == 0 && col == 0) { return "p1";  }
        if (row == 0 && col == 2) { return "p01"; }
        if (row == 1 && col == 0) { return "m1";  }
        if (row == 1 && col == 2) { return "m01"; }
        if (row == 1 && col == 1) { return "ok";  }
        return "";
    }

    (:touchInput)
    function handleInput(z) {
        if (z.equals("p1"))       { bump(10);  }
        else if (z.equals("p01")) { bump(1);   }
        else if (z.equals("m1"))  { bump(-10); }
        else if (z.equals("m01")) { bump(-1);  }
        else if (z.equals("ok"))  { confirmLactate(); }
        else if (z.equals("back")){ _mode = 0; clampTop(); WatchUi.requestUpdate(); }
    }

    // ——— тап в режиме списка ———
    function handleListTap(x, y) {
        if (!_touchOn) { return; }   // тач выключен/отсутствует — игнорируем
        // правый край при включённом лактате — переход в ввод
        if (_lactateEnabled && x > _w - zoneW()) {
            _mode = 1;
            WatchUi.requestUpdate();
            return;
        }
        var third = _h / 3;
        if (y < third) { pageOlder(); }
        else if (y > third * 2) { pageNewer(); }
        else {
            // центр-тап переключает плотность списка только в режиме "Cycle by tap"
            if (_listMode == 3) {
                _fontMode = (_fontMode + 1) % 3;
                clampTop();
            }
        }
        _tapFlash = 3;
        WatchUi.requestUpdate();
    }

    // ——— отрисовка ———
    function onUpdate(dc) {
        if (_fontIds == null) { onLayout(dc); }
        if (_fontPage != _mode*3+_fontMode) { resetFonts(); }
        if (dc has :setAntiAlias) { dc.setAntiAlias(true); }   // API 3.2+ по документации SDK (TSV-24); has обязателен: fr645, fr935 (3.1) и fr735xt (2.4) его не имеют (TSV-25)
        if (_settingsError != null) { drawError(dc); return; }
        if (_mode == 1 && (self has :drawInput)) { drawInput(dc); }
        else { drawList(dc); }
    }

    function drawError(dc) {
        dc.setColor(_fg, _bg); dc.clear();
        lineText(dc,"Settings error",227,136,340,12,paletteColor(5,_light),Graphics.TEXT_JUSTIFY_CENTER);
        lineText(dc,_settingsError,227,210,360,12,_fg,Graphics.TEXT_JUSTIFY_CENTER);
        lineText(dc,"Use mm:ss (e.g. 4:30)",227,274,340,12,_fg,Graphics.TEXT_JUSTIFY_CENTER);
    }

    // TSV-35: принятые холсты TSV-34, координаты канонического экрана 454×454.
    // На прямоугольном/полукруглом экране композиция вписана в меньшую сторону.
    function sc(v) { return (v * ((_w < _h) ? _w : _h) / 454.0 + 0.5).toNumber(); }
    function px(v) { return (_w - sc(454)) / 2 + sc(v); }
    function py(v) { return (_h - sc(454)) / 2 + sc(v); }

    // Обычный текст по центру видимой высоты цифр, в том числе прежний ввод лактата.
    (:touchInput)
    function txt(dc, x, y, font, s, color, justify) {
        var dh = sc(font == _fBig ? 47 : ((font == _fKey || font == font(10)) ? 27 : 14));
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y + dh / 2 - Graphics.getFontAscent(font), font, s, justify);
    }

    (:touchInput)
    function drop(dc, x, y, h, color) {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(x, y + h * 0.25, h * 0.35);
        dc.fillPolygon([ [x, y - h * 0.5], [x - h * 0.309, y + h * 0.087], [x + h * 0.309, y + h * 0.087] ]);
    }
    (:touchInput)
    function chevron(dc, x, y, dir, color) {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(sc(3));
        dc.drawLine(x - sc(4) * dir, y - sc(8), x + sc(4) * dir, y);
        dc.drawLine(x + sc(4) * dir, y, x - sc(4) * dir, y + sc(8));
        dc.setPenWidth(1);
    }

    // Шрифты перечислены от меньшего к большему. Длинное значение уменьшается до
    // доступной ширины, никогда не переносится и не обрезается (TSV-34/35).
    function fitFont(dc, s, f, width) {
        while (f > 0 && dc.getTextWidthInPixels(s, font(f)) > sc(width)) { f -= 1; }
        return f;
    }
    function lineText(dc, s, x, y, width, f, color, align) {
        f = fitFont(dc, s, f, width);
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(px(x), py(y), font(f), s, align);
        return f;
    }
    function valueText(dc, s, x, y, width, f, color, align) {
        f = lineText(dc, s, x, y, width, f, color, align);
        // Низ видимых цифр, а не низ типографской строки: подпись строго через 5px.
        return y + _digitBottom[f];
    }
    function labelText(dc, s, x, inkTop, width, color) {
        lineText(dc, s, x, inkTop - 6, width, 1, color, Graphics.TEXT_JUSTIFY_LEFT);
    }
    function liveColor() { return paletteColor(1, _light); }
    function cardBackground(dc, it as Array, x, y, w, h, radius) {
        var live = it[0] == 0 && it[5] == -1;
        dc.setColor(live ? (_light ? 0xE2F5FC : 0x082B3C) : (_light ? 0xEAF3ED : 0x17231D), Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(px(x), py(y), sc(w), sc(h), sc(radius));
        if (live) {
            dc.setColor(liveColor(), Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(sc(2));
            dc.drawRoundedRectangle(px(x+1), py(y+1), sc(w-2), sc(h-2), sc(radius));
            dc.setPenWidth(1);
            lineText(dc, "LIVE", x+62, y+2, 45, 9, liveColor(), Graphics.TEXT_JUSTIFY_LEFT);
        }
    }
    function drawList(dc) {
        clampTop();
        dc.setColor(_fg, _bg); dc.clear();
        if (_fontMode == 2) { drawCard(dc, itemAt(_topIndex)); }
        else { drawCarousel(dc); }
        if (_lactateEnabled && (self has :drawRightSwitch)) { drawRightSwitch(dc); }
        if (_tapFlash > 0) {
            dc.setColor(_dim, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(0, 0, _w, (_h*0.013).toNumber());
            _tapFlash -= 1;
        }
    }
    function zoneW() { return (_w * 0.16).toNumber() - 5; }
    function valOf(v10) { return (v10/10).format("%d") + "," + (v10%10).format("%d"); }

    function drawCarousel(dc) {
        var rows = rowsForMode(_fontMode);
        for (var i = 0; i < rows; i += 1) {
            var idx = _topIndex + i - (rows / 2);
            if (idx < 0 || idx >= nItems()) { continue; }
            var x = 81; var y = 49+i*60; var w = 278; var h = 56; var size = 3;
            if (_fontMode == 1) {
                if (i == 0 || i == 4) { x=117; w=184; h=52; size=1; }
                else if (i == 2) { x=34; w=350; h=115.4; size=6; }
                else { x=70; }
                if (i == 0) { y=36; }
                else if (i == 1) { y=94; }
                else if (i == 2) { y=156; }
                else if (i == 3) { y=277.4; }
                else { y=339.4; }
            }
            drawSplit(dc, itemAt(idx), x, y, w, h, size);
        }
    }
    function drawSplit(dc, it as Array, x, y, w, h, size) {
        var active = size == 6;
        cardBackground(dc, it, x,y,w,h,active ? 12 : 8);
        var left=x+(active ? 12 : 8); var right=x+w-(active ? 12 : 8);
        var l = Graphics.TEXT_JUSTIFY_LEFT; var r = Graphics.TEXT_JUSTIFY_RIGHT;
        if (it[0] == 1) {
            lineText(dc,"lactate",left,y+(active ? 10 : 4),w/2,active ? 2 : 0,liveColor(),l);
            lineText(dc,"mmol/L",right,y+2,w/2,1,_dim,r);
            var bottom = valueText(dc,valOf(it[1]),left,y+(active ? 44 : 26),w/2,size,liveColor(),l);
            valueText(dc,fmtClock(it[2]),right,y+(active ? 44 : 26),w/2,size,_dim,r);
            if (active) { labelText(dc,"value",left,bottom+5,100,_dim); labelText(dc,"time",right-60,bottom+5,60,_dim); }
            return;
        }
        lineText(dc,it[1].format("%d"),left,y+(active ? 10 : 4),64,active ? 2 : 0,paletteColor(6,_light),l);
        lineText(dc,it[3].toNumber().format("%d"),right,y+(active ? 0 : 2),w-84,active ? 4 : 1,_fg,r);
        var ty = y+(active ? 44 : 26);
        if (size == 1) { ty=y+26; }
        var time = fmtTime(it[2]); var pace=fmtPaceU(it[4]); var unit="/"+distUnit();
        var uw=dc.getTextWidthInPixels(unit,font(1));
        var unitWidth=uw*454.0/((_w < _h) ? _w : _h);
        var available=(w-(active ? 24 : 16))/2;
        var f = fitFont(dc,pace,size,available-unitWidth);
        var pw=dc.getTextWidthInPixels(pace,font(f));
        var paceX=right-unitWidth;
        var bottom=valueText(dc,time,left,ty,available,size,_fg,l);
        var pb=valueText(dc,pace,paceX,ty,available-unitWidth,f,it[5] == -1 ? _fg : colorFor(it[4]),r);
        // Суффикс выровнен по видимой базовой линии цифр, включая уменьшение длинного темпа.
        lineText(dc,unit,right,ty+_digitBottom[f]-20,unitWidth,1,_dim,r);
        if (active) {
            labelText(dc,"time",left,bottom+5,70,_dim);
            labelText(dc,"pace",paceX-pw*454.0/((_w < _h) ? _w : _h),pb+5,70,_dim);
        }
    }
    function drawCard(dc, it as Array) {
        var live=it[0] == 0 && it[5] == -1;
        var l=Graphics.TEXT_JUSTIFY_LEFT; var mid=Graphics.TEXT_JUSTIFY_CENTER;
        if (live) {
            dc.setColor(_light ? 0xE2F5FC : 0x082B3C, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(px(227),py(227),sc(227));
            dc.setColor(liveColor(),Graphics.COLOR_TRANSPARENT); dc.setPenWidth(sc(2));
            dc.drawCircle(px(227),py(227),sc(226)); dc.setPenWidth(1);
            lineText(dc,"LIVE",258,50,48,9,liveColor(),l);
        }
        if (it[0] == 1) {
            lineText(dc,"lactate",209,48,150,1,liveColor(),mid);
            lineText(dc,"mmol/L",209,78,150,1,_dim,mid);
            var value=valOf(it[1]); var vf=fitFont(dc,value,8,326);
            var vw=dc.getTextWidthInPixels(value,font(vf))*454.0/((_w < _h) ? _w : _h);
            labelText(dc,"value",209-vw/2,156,80,_dim);
            valueText(dc,value,209,156.67,326,vf,liveColor(),mid);
            var clock=fmtClock(it[2]); var cf=fitFont(dc,clock,8,300);
            var cw=dc.getTextWidthInPixels(clock,font(cf))*454.0/((_w < _h) ? _w : _h);
            labelText(dc,"time",209-cw/2,268,80,_dim);
            valueText(dc,clock,209,272.67,300,cf,_dim,mid);
            return;
        }
        lineText(dc,it[1].format("%d"),209,48,64,2,paletteColor(6,_light),mid);
        lineText(dc,it[3].toNumber().format("%d"),209,78,250,5,_fg,mid);
        var time=fmtTime(it[2]); var f=fitFont(dc,time,8,326);
        var tw=dc.getTextWidthInPixels(time,font(f))*454.0/((_w < _h) ? _w : _h);
        labelText(dc,"time",209-tw/2,156,80,_dim);
        valueText(dc,time,209,156.67,326,f,_fg,mid);
        var pace=fmtPaceU(it[4]); var unit="/"+distUnit();
        var uw=dc.getTextWidthInPixels(unit,font(1))*454.0/((_w < _h) ? _w : _h);
        f=fitFont(dc,pace,8,300-uw);
        var pw=dc.getTextWidthInPixels(pace,font(f))*454.0/((_w < _h) ? _w : _h);
        var x=209-(pw+uw)/2;
        labelText(dc,"pace",x,268,80,_dim);
        valueText(dc,pace,x,272.67,300-uw,f,live ? _fg : colorFor(it[4]),l);
        lineText(dc,unit,x+pw,272.67+_digitBottom[f]-20,uw,1,_dim,l);
    }
    (:touchInput)
    function drawRightSwitch(dc) {
        dc.setColor(_fg, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(px(386),py(195),sc(64),sc(64),sc(20));
        drop(dc,px(418),py(227),sc(36),_bg);
    }

    // ввод: зоны те же (3×2), но без заливок — линии, «+»/«-» цветом текста, OK — единственная плотная плашка
    (:touchInput)
    function drawInput(dc) {
        var cw = _w/3; var rh = _h/2;
        dc.setColor(_fg, _bg); dc.clear();

        dc.setColor(_line, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawLine(cw, sc(60), cw, _h - sc(60));
        dc.drawLine(2*cw, sc(60), 2*cw, _h - sc(60));
        dc.drawLine(sc(40), rh, _w - sc(40), rh);
        dc.setPenWidth(1);

        // подписи прижаты к центру экрана: верхние (+1,+0,1) — в нижнюю треть своей зоны, нижние — в верхнюю
        var topY = (rh * 0.72).toNumber();
        var botY = (rh + rh * 0.28).toNumber();
        var up = paletteColor(2, _light);
        var down = paletteColor(5, _light);
        var mid = Graphics.TEXT_JUSTIFY_CENTER;
        txt(dc, cw/2 + sc(10), topY, _fKey, "+1", up, mid);
        txt(dc, 2*cw + cw/2 - sc(10), topY, _fKey, "+0,1", up, mid);
        txt(dc, cw/2 + sc(10), botY, _fKey, "-1", down, mid);
        txt(dc, 2*cw + cw/2 - sc(10), botY, _fKey, "-0,1", down, mid);

        // значение — в нижнюю треть верхнего ряда (к центру), над ним капля
        drop(dc, cw + cw/2, (rh * 0.30).toNumber(), sc(26), paletteColor(1, _light));
        txt(dc, cw + cw/2, topY - sc(4), _fBig, valStr(), _fg, mid);

        // OK — светлая (в тёмной теме) или чёрная (в светлой) плашка
        dc.setColor(_fg, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(cw + sc(14), rh + sc(14), cw - sc(28), (rh * 0.5).toNumber(), sc(24));
        txt(dc, cw + cw/2, rh + sc(14) + (rh * 0.25).toNumber(), font(10), "OK", _bg, mid);

        // левый край — возврат: капля и стрелка влево
        var bw = zoneW();
        dc.setColor(_line, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(sc(3));
        dc.drawRoundedRectangle(-sc(20), rh - sc(45), bw + sc(6), sc(90), sc(16));
        dc.setPenWidth(1);
        chevron(dc, bw / 2 - sc(7), rh - sc(24), -1, _fg);
        drop(dc, bw / 2 - sc(7), rh + sc(16), sc(24), _fg);
    }
}

class SplitsDelegate extends WatchUi.BehaviorDelegate {
    var _view;
    function initialize(v) { BehaviorDelegate.initialize(); _view = v; }
    function onTap(evt) {
        var c = evt.getCoordinates();
        if (_view._mode == 1 && (_view has :handleInput) && (_view has :inputZoneAt)) {
            _view.handleInput(_view.inputZoneAt(c[0], c[1]));
        } else {
            _view.handleListTap(c[0], c[1]);
        }
        return true;
    }
}
