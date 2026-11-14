import Toybox.Application;
import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.Activity;
import Toybox.Lang;
import Toybox.System;

// TSV-37: лактат здесь больше не рисуется и не пишется. Его пишет отдельное поле
// в каталоге lactate/ (свой app id, те же номера полей 1 и 2). Список кругов
// из-за этого не делит экран с вводом.
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
    // Запись круга: [0, lapNum, lapTimeSec, lapDistM, paceSec, tMsAbs]
    var _items;            // список кругов по времени добавления
    var _lastTimeMs; var _lastDistM;
    var _topIndex; var _fontMode; var _w; var _h; var _tapFlash;
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
    var _bg; var _fg; var _dim;
    var _fonts as Array or Null;
    var _fontIds as Array or Null; var _fontPage = -1; var _lowMemory; var _cachedFont = -1;
    // Низ видимых цифр относительно начала строки, Golos Text на 454 (tools/make_fonts.py).
    var _digitBottom as Array = [16,20,20,24,36,40,48,63,71,16];

    function initialize() {
        DataField.initialize();
        _items = [];
        _lastTimeMs = 0; _lastDistM = 0.0;
        _topIndex = 0; _w = 0; _h = 0; _tapFlash = 0;
        _curLapTime = 0.0; _curLapDist = 0.0; _curLapPace = 0.0;
        _fontMode = 0;
        _settingsError = null;
        _touchOn = true; _cycleSec = 5; _cycleAccum = 0;
        _lapCount = 0;
        reloadSettings();
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
        if (_light) { _bg = 0xFFFFFF; _fg = 0x000000; _dim = 0x6A6A6A; }
        else        { _bg = 0x000000; _fg = 0xDCDCDC; _dim = 0x7A7A7A; }

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
        if (_listMode == 4) {
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
        _fonts = new [13];
        _cachedFont=-1;
        _fontPage = _fontMode;
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

    // ——— тап в режиме списка ———
    function handleListTap(x, y) {
        if (!_touchOn) { return; }   // тач выключен/отсутствует — игнорируем
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
        if (_fontPage != _fontMode) { resetFonts(); }
        if (dc has :setAntiAlias) { dc.setAntiAlias(true); }   // API 3.2+ по документации SDK (TSV-24); has обязателен: fr645, fr935 (3.1) и fr735xt (2.4) его не имеют (TSV-25)
        if (_settingsError != null) { drawError(dc); return; }
        drawList(dc);
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
        if (_tapFlash > 0) {
            dc.setColor(_dim, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(0, 0, _w, (_h*0.013).toNumber());
            _tapFlash -= 1;
        }
    }
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
}

class SplitsDelegate extends WatchUi.BehaviorDelegate {
    var _view;
    function initialize(v) { BehaviorDelegate.initialize(); _view = v; }
    function onTap(evt) {
        var c = evt.getCoordinates();
        _view.handleListTap(c[0], c[1]);
        return true;
    }
}
