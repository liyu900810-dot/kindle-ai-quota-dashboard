(function (win, doc) {
  'use strict';

  var settings = {
    fallbackData: 'data.js',
    endpointPointer: 'live-endpoint.js',
    pollEvery: 3 * 60 * 1000,
    pollOffset: 5000,
    delayAfterMinutes: 10,
    offlineAfterMinutes: 30,
    quietStart: 3,
    quietEnd: 8
  };
  var state = {
    endpoint: win.DASH_LIVE_ENDPOINT || settings.fallbackData,
    latest: null,
    renderedAt: ''
  };
  var weekdays = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];

  var ui = {
    find: function (id) {
      return doc.getElementById(id);
    },
    textNode: function (node, value) {
      var next = String(value);
      if (node && node.textContent !== next) node.textContent = next;
    },
    text: function (id, value) {
      ui.textNode(ui.find(id), value);
    },
    html: function (node, value) {
      if (node && node.innerHTML !== value) node.innerHTML = value;
    },
    className: function (node, value) {
      if (node && node.className !== value) node.className = value;
    },
    style: function (node, name, value) {
      if (node && node.style[name] !== value) node.style[name] = value;
    },
    attribute: function (node, name, value) {
      var next = String(value);
      if (node && node.getAttribute(name) !== next) node.setAttribute(name, next);
    }
  };

  function twoDigits(value) {
    return value < 10 ? '0' + value : String(value);
  }

  function timestamp(value) {
    var parsed = Date.parse(value || '');
    return isNaN(parsed) ? 0 : parsed;
  }

  function clockText(value) {
    var date = new Date(value);
    if (isNaN(date.getTime())) return '--:--';
    return twoDigits(date.getHours()) + ':' + twoDigits(date.getMinutes());
  }

  function isQuiet(date) {
    var hour = (date || new Date()).getHours();
    return hour >= settings.quietStart && hour < settings.quietEnd;
  }

  function millisecondsUntilMorning(date) {
    var now = date || new Date();
    var morning = new Date(
      now.getFullYear(),
      now.getMonth(),
      now.getDate(),
      settings.quietEnd,
      0,
      5,
      0
    );
    return Math.max(1000, morning.getTime() - now.getTime());
  }

  function updateFreshness() {
    var lastUpdate = state.latest && state.latest.updatedAt;
    var age = lastUpdate
      ? Math.floor((Date.now() - timestamp(lastUpdate)) / 60000)
      : 99999;
    var lastClock = clockText(lastUpdate);
    var status = ui.find('dataStatus');
    var alert = ui.find('dataAlert');

    if (state.latest) {
      ui.text('relTime', age < 1 ? '刚刚更新' : age + '分钟前更新');
    }

    if (isQuiet()) {
      ui.textNode(status, '夜间省电 · 08:00恢复');
      ui.className(status, '');
      ui.textNode(alert, '');
      ui.className(alert, 'data-alert');
      return;
    }

    if (!state.latest || age > settings.offlineAfterMinutes) {
      ui.textNode(status, '离线 · 最后 ' + lastClock);
      ui.className(status, 'warn');
      ui.textNode(alert, '电脑或数据链路已离线 · 最后在线 ' + lastClock);
      ui.className(alert, 'data-alert on');
      return;
    }

    if (age >= settings.delayAfterMinutes) {
      ui.textNode(status, '延迟 ' + age + ' 分钟 · ' + lastClock);
      ui.className(status, 'warn');
      ui.textNode(alert, '实时数据延迟 ' + age + ' 分钟 · 正在显示最后一次结果');
      ui.className(alert, 'data-alert on');
      return;
    }

    ui.textNode(status, '实时 · ' + lastClock);
    ui.className(status, '');
    ui.textNode(alert, '');
    ui.className(alert, 'data-alert');
  }

  function updateClock() {
    var now = new Date();
    var time = twoDigits(now.getHours()) + ':' + twoDigits(now.getMinutes());
    var calendar = state.latest && state.latest.calendar;
    ui.text('clock', time);
    ui.text('dtTime', time);
    ui.text('solarDate', calendar && calendar.solar || formatDate(now));
    ui.text('lunarDate', calendar && calendar.lunar || '农历日期');
    ui.text('dtDate', calendar && calendar.solar || formatDate(now));
    ui.text('dtLunar', calendar && calendar.lunar || '农历日期');
    updateFreshness();
  }

  function queryValue(name) {
    var match = String(location.search || '').match(
      new RegExp('[?&]' + name + '=([^&]*)')
    );
    return match ? decodeURIComponent(match[1]) : null;
  }

  function updateBattery() {
    var percentText = queryValue('battery');
    var chargeText = queryValue('charging');
    var percent = percentText !== null ? Number(percentText) : null;
    var charging = chargeText === '1';
    var device = win.KINDLE_DEVICE;

    if (device) {
      if (typeof device.battery === 'number') percent = device.battery;
      if (typeof device.charging === 'boolean') charging = device.charging;
      if (device.charging === 0 || device.charging === 1) charging = device.charging === 1;
    }
    if (percent === null || isNaN(percent)) return;

    percent = Math.max(0, Math.min(100, percent));
    ui.text('batPct', (charging ? '⚡ ' : '') + percent + '%');
    ui.attribute(ui.find('batFill'), 'width', Math.round(18 * percent / 100));
  }

  function attachScript(url, onSuccess, onFailure) {
    var script = doc.createElement('script');
    script.async = true;
    script.src = url;
    script.onload = function () {
      if (script.parentNode) script.parentNode.removeChild(script);
      if (onSuccess) onSuccess();
    };
    script.onerror = function () {
      if (script.parentNode) script.parentNode.removeChild(script);
      if (onFailure) onFailure();
    };
    doc.getElementsByTagName('head')[0].appendChild(script);
  }

  function requestDeviceStatus() {
    attachScript('device-status.js?_=' + Date.now(), updateBattery);
  }

  function windowTitle(value) {
    var name = String(value || '');
    if (/5小时|5H/i.test(name)) return '5小时';
    if (/7天|周|WEEK/i.test(name)) return '周';
    if (/月|MONTH/i.test(name)) return '月';
    return name || 'QUOTA';
  }

  function remainingTime(value) {
    var remaining = timestamp(value) - Date.now();
    var minutes;
    var days;
    var hours;
    if (!value || !remaining) return '↻ 未提供刷新时间';
    if (remaining <= 0) return '↻ 即将刷新';

    minutes = Math.ceil(remaining / 60000);
    days = Math.floor(minutes / 1440);
    hours = Math.floor((minutes % 1440) / 60);
    minutes %= 60;
    if (days) return '↻ ' + days + 'd' + (hours ? ' ' + hours + 'h' : '');
    if (hours) return '↻ ' + hours + 'h' + twoDigits(minutes) + 'm';
    return '↻ ' + minutes + 'm';
  }

  function showUnavailableQuota(rows) {
    var labels;
    if (!rows.length) return;
    ui.style(rows[0], 'display', 'block');
    labels = rows[0].querySelectorAll('.q-label span');
    if (labels.length > 1) {
      ui.textNode(labels[0], '获取失败');
      ui.textNode(labels[1], '--');
    }
    ui.style(rows[0].querySelector('.q-bar-fill'), 'width', '0%');
    ui.textNode(rows[0].querySelector('.q-refresh'), '↻ 等待下次采集');
  }

  function updateQuotaCard(cardId, source) {
    var card = ui.find(cardId);
    var rows;
    var windows;
    var index;
    if (!card) return;

    rows = card.querySelectorAll('.q-row');
    windows = source && source.ok && source.windows ? source.windows : [];
    for (index = 0; index < rows.length; index += 1) {
      var quotaWindow;
      var labels;
      var percentage;
      if (index >= windows.length) {
        ui.style(rows[index], 'display', 'none');
        continue;
      }

      quotaWindow = windows[index];
      ui.style(rows[index], 'display', 'block');
      labels = rows[index].querySelectorAll('.q-label span');
      if (labels.length > 1) {
        ui.textNode(labels[0], windowTitle(quotaWindow.name));
        ui.textNode(
          labels[1],
          quotaWindow.displayValue != null
            ? String(quotaWindow.displayValue)
            : Math.round(Number(quotaWindow.usedPct) || 0) + '%'
        );
      }

      percentage = quotaWindow.barPct != null
        ? quotaWindow.barPct
        : quotaWindow.usedPct;
      ui.style(
        rows[index].querySelector('.q-bar-fill'),
        'width',
        Math.max(0, Math.min(100, Number(percentage) || 0)) + '%'
      );
      ui.textNode(
        rows[index].querySelector('.q-refresh'),
        quotaWindow.detailText || remainingTime(quotaWindow.resetAt)
      );
    }
    if (!windows.length) showUnavailableQuota(rows);
  }

  function selectWeatherIcon(key, description) {
    var text = (String(key || '') + ' ' + String(description || '')).toLowerCase();
    if (/unknown|未知/.test(text)) return 'unknown';
    if (/clear-night/.test(text)) return 'moon';
    if (/thunder|雷/.test(text)) return 'thunder';
    if (/snow|雪/.test(text)) return 'snow';
    if (/rain|wet|雨/.test(text)) return 'rain';
    if (/fog|mist|haze|雾/.test(text)) return 'fog';
    if (/clear|sun|晴/.test(text)) return 'clear';
    return 'cloud';
  }

  function weatherIconSvg(key, description) {
    var icon = selectWeatherIcon(key, description);
    var start = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48" role="img" focusable="false">';
    var end = '</svg>';
    if (icon === 'moon') {
      return start + '<path d="M34 34A16 16 0 0 1 21 8a16 16 0 1 0 13 26Z"/>' + end;
    }
    if (icon === 'unknown') {
      return start + '<circle cx="24" cy="24" r="18"/><path d="M18 18a7 7 0 1 1 9 7c-3 1-3 3-3 5M24 37h.1"/>' + end;
    }
    if (icon === 'clear') {
      return start + '<circle cx="24" cy="24" r="8"/><path d="M24 4v7M24 37v7M4 24h7M37 24h7M9.9 9.9l5 5M33.1 33.1l5 5M38.1 9.9l-5 5M14.9 33.1l-5 5"/>' + end;
    }
    if (icon === 'rain') {
      return start + '<path d="M10 25h25c4 0 7-3 7-7s-3-7-7-7h-1a11 11 0 0 0-21 3h-3c-4 0-7 3-7 7s3 4 7 4Z"/><path d="M16 33l-3 6M25 33l-3 6M34 33l-3 6"/>' + end;
    }
    if (icon === 'snow') {
      return start + '<path d="M10 25h25c4 0 7-3 7-7s-3-7-7-7h-1a11 11 0 0 0-21 3h-3c-4 0-7 3-7 7s3 4 7 4Z"/><path d="M16 33v10M12 35l8 6M20 35l-8 6M31 33v10M27 35l8 6M35 35l-8 6"/>' + end;
    }
    if (icon === 'fog') {
      return start + '<path d="M7 18h34M4 25h40M8 32h32M14 39h20"/>' + end;
    }
    if (icon === 'thunder') {
      return start + '<path d="M10 25h25c4 0 7-3 7-7s-3-7-7-7h-1a11 11 0 0 0-21 3h-3c-4 0-7 3-7 7s3 4 7 4Z"/><path d="M26 29l-6 9h5l-3 7 8-11h-5l5-5Z"/>' + end;
    }
    return start + '<path d="M10 25h25c4 0 7-3 7-7s-3-7-7-7h-1a11 11 0 0 0-21 3h-3c-4 0-7 3-7 7s3 4 7 4Z"/>' + end;
  }

  function rounded(value, fallback) {
    if (value === null || value === undefined || value === '') return fallback;
    var number = Number(value);
    return isFinite(number) ? String(Math.round(number)) : fallback;
  }

  function updateWeather(weather) {
    if (!weather || !weather.ok) return;
    ui.text('weatherCity', weather.place || '扬州');
    ui.text('weatherDescription', weather.description || 'Sunny');
    ui.text('weatherTemp', rounded(weather.tempC, '--') + ' C');
    ui.text('weatherFeels', '体感 ' + rounded(weather.feelsLikeC, '--') + ' C');
    ui.text('weatherHumidity', '湿度 ' + rounded(weather.humidity, '--') + '%');
    ui.text(
      'weatherWind',
      (weather.windDir || '风') + ' ' + rounded(weather.windKph, '--') + ' km/h'
    );
    ui.text(
      'weatherSource',
      'Weather: Open-Meteo' + (weather.stale ? ' · 缓存' : '')
    );
    ui.html(ui.find('weatherIcon'), weatherIconSvg(weather.iconKey, weather.description));
  }

  function updateBalance(source) {
    if (source && source.ok && typeof source.balance === 'number') {
      ui.text('deepSeekBalance', '¥ ' + Number(source.balance).toFixed(2));
      ui.text('deepSeekDetail', '实时余额 · 按量计费');
      return;
    }
    ui.text('deepSeekBalance', '¥ --');
    ui.text('deepSeekDetail', '获取失败 · 等待下次采集');
  }

  function updateQuote(quote) {
    var card = ui.find('quoteCard');
    if (!card) return;
    if (!quote || !quote.text) {
      card.hidden = true;
      return;
    }
    card.hidden = false;
    ui.text('quoteText', quote.text);
    ui.text('quoteSource', quote.source ? '— ' + quote.source : '');
  }

  function present(data) {
    var relativeNode;
    if (!data || !data.updatedAt || !data.sources) return;
    if (state.renderedAt && timestamp(data.updatedAt) < timestamp(state.renderedAt)) return;

    state.latest = data;
    if (data.updatedAt !== state.renderedAt) {
      state.renderedAt = data.updatedAt;
      updateClock();
      updateWeather(data.weather);
      updateQuotaCard('cardClaude', data.sources.claude);
      updateQuotaCard('cardCodex', data.sources.codex);
      updateQuotaCard('cardKimi', data.sources.kimi);
      updateBalance(data.sources.deepseek);
      updateQuote(data.quote);
      relativeNode = ui.find('relTime');
      if (relativeNode) ui.attribute(relativeNode, 'data-ts', data.updatedAt);
    }
    updateFreshness();
  }

  function requestData(url, canFallback) {
    var separator;
    if (!url || url.indexOf('__LIVE_') === 0) return;
    separator = url.indexOf('?') < 0 ? '?' : '&';
    attachScript(
      url + separator + '_=' + Date.now(),
      function () {
        present(win.DASH_DATA);
      },
      function () {
        if (canFallback && url !== settings.fallbackData) {
          requestData(settings.fallbackData, false);
        }
      }
    );
  }

  function refresh() {
    requestDeviceStatus();
    attachScript(
      settings.endpointPointer + '?_=' + Date.now(),
      function () {
        var supplied = win.DASH_LIVE_ENDPOINT || '';
        if (supplied && supplied.indexOf('__LIVE_') !== 0) state.endpoint = supplied;
        requestData(state.endpoint, true);
      },
      function () {
        state.endpoint = settings.fallbackData;
        requestData(state.endpoint, false);
      }
    );
  }

  function scheduleRefresh() {
    var now = new Date();
    var milliseconds = now.getTime();
    var delay;

    if (isQuiet(now)) {
      delay = millisecondsUntilMorning(now);
    } else {
      delay = (
        settings.pollOffset -
        (milliseconds % settings.pollEvery) +
        settings.pollEvery
      ) % settings.pollEvery;
      if (delay < 250) delay += settings.pollEvery;
    }

    setTimeout(function () {
      if (!isQuiet()) refresh();
      scheduleRefresh();
    }, delay);
  }

  function scheduleMinuteClock() {
    var now = new Date();
    var delay = isQuiet(now)
      ? millisecondsUntilMorning(now)
      : 60000 - (now.getTime() % 60000) + 100;
    setTimeout(function () {
      updateClock();
      scheduleMinuteClock();
    }, delay);
  }

  present(win.DASH_DATA);
  updateClock();
  updateBattery();
  if (!isQuiet()) refresh();
  scheduleRefresh();
  scheduleMinuteClock();
}(window, document));
