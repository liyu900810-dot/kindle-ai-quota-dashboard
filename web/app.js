(function () {
  'use strict';

  var REFRESH_MS = 3 * 60 * 1000;
  var refreshScript = null;

  function byId(id) {
    return document.getElementById(id);
  }

  function pad(value) {
    return value < 10 ? '0' + value : String(value);
  }

  function formatDate(date) {
    var week = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
    return date.getFullYear() + '年' + (date.getMonth() + 1) + '月' + date.getDate() + '日 ' + week[date.getDay()];
  }

  function updateClock() {
    var now = new Date();
    byId('clock').innerHTML = pad(now.getHours()) + ':' + pad(now.getMinutes());
    byId('date').innerHTML = formatDate(now);
  }

  function queryValue(name) {
    var query = String(window.location.search || '').replace(/^\?/, '').split('&');
    var i;
    for (i = 0; i < query.length; i += 1) {
      var pair = query[i].split('=');
      if (decodeURIComponent(pair[0] || '') === name) return decodeURIComponent(pair[1] || '');
    }
    return '';
  }

  function renderBattery() {
    var battery = queryValue('battery');
    byId('battery').innerHTML = battery ? '电量 ' + battery + '%' : '电量由 Kindle 启动器提供';
  }

  function weatherSymbol(key) {
    var value = String(key || '').toLowerCase();
    if (value.indexOf('rain') >= 0) return '☂';
    if (value.indexOf('snow') >= 0) return '✳';
    if (value.indexOf('clear') >= 0 || value.indexOf('sun') >= 0) return '☀';
    if (value.indexOf('cloud') >= 0 || value.indexOf('overcast') >= 0) return '☁';
    return '○';
  }

  function renderWeather(weather) {
    if (!weather || !weather.ok) {
      byId('temperature').innerHTML = '--°';
      byId('weatherIcon').innerHTML = '○';
      byId('weatherDetail').innerHTML = '天气未配置';
      byId('weatherWind').innerHTML = weather && weather.error ? weather.error : '等待数据';
      return;
    }
    byId('temperature').innerHTML = weather.tempC == null ? '--°' : Math.round(weather.tempC) + '°';
    byId('weatherIcon').innerHTML = weatherSymbol(weather.iconKey);
    byId('weatherDetail').innerHTML =
      (weather.description || '天气') +
      (weather.feelsLikeC == null ? '' : ' · 体感 ' + Math.round(weather.feelsLikeC) + '°') +
      (weather.humidity == null ? '' : ' · 湿度 ' + Math.round(weather.humidity) + '%');
    byId('weatherWind').innerHTML =
      (weather.windKph == null ? '' : '风 ' + Math.round(weather.windKph) + 'km/h') +
      (weather.windDir ? ' · ' + weather.windDir : '') +
      (weather.place ? ' · ' + weather.place : '');
  }

  function escapeHtml(value) {
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function resetText(resetAt) {
    if (!resetAt) return '重置时间未知';
    var target = new Date(resetAt);
    if (!isFinite(target.getTime())) return '重置时间未知';
    var seconds = Math.max(0, Math.floor((target.getTime() - Date.now()) / 1000));
    var days = Math.floor(seconds / 86400);
    var hours = Math.floor((seconds % 86400) / 3600);
    var minutes = Math.floor((seconds % 3600) / 60);
    if (days > 0) return days + '天' + hours + '小时后重置';
    if (hours > 0) return hours + '小时' + minutes + '分钟后重置';
    return minutes + '分钟后重置';
  }

  function renderWindow(item) {
    var used = Math.max(0, Math.min(100, Number(item.usedPct || 0)));
    return '<div class="window">' +
      '<div class="window-head"><span class="window-name">' + escapeHtml(item.name) + '</span>' +
      '<span class="window-value">' + Math.round(used) + '%</span></div>' +
      '<div class="bar"><div class="bar-fill" style="width:' + used + '%"></div></div>' +
      '<div class="reset">' + escapeHtml(resetText(item.resetAt)) + '</div>' +
      '</div>';
  }

  function renderSource(card, source, name) {
    var content = card.querySelector('.card-content');
    var heading = card.querySelector('h2');
    var stale = source && source.stale ? '<span class="stale">旧值</span>' : '';
    heading.innerHTML = escapeHtml(source && source.label || name) + stale;
    if (!source || !source.ok) {
      content.innerHTML = '<div class="source-error">' +
        escapeHtml(source && source.disabled ? '未启用' : source && source.error || '没有数据') +
        '</div>';
      return;
    }
    if (name === 'deepseek') {
      var prefix = source.currency === 'CNY' ? '¥ ' : escapeHtml(source.currency || '') + ' ';
      content.innerHTML = '<div class="balance">' + prefix +
        escapeHtml(Number(source.balance).toFixed(2)) + '</div>' +
        '<div class="balance-detail">' + escapeHtml(source.detail || '实时余额') + '</div>';
      return;
    }
    var html = '';
    var windows = source.windows || [];
    var i;
    for (i = 0; i < windows.length; i += 1) html += renderWindow(windows[i]);
    content.innerHTML = html || '<div class="source-error">没有可显示的额度窗口</div>';
  }

  function render(data) {
    if (!data || !data.sources) return;
    renderWeather(data.weather);
    var quote = data.quote || {};
    byId('quoteText').innerHTML = escapeHtml(quote.text || '今天还没有设置句子。');
    byId('quoteSource').innerHTML = quote.source ? '— ' + escapeHtml(quote.source) : '';
    var cards = document.querySelectorAll('.quota-card');
    var i;
    for (i = 0; i < cards.length; i += 1) {
      var name = cards[i].getAttribute('data-source');
      renderSource(cards[i], data.sources[name], name);
    }
    var updated = data.updatedAt ? new Date(data.updatedAt) : null;
    byId('updatedAt').innerHTML = updated && isFinite(updated.getTime())
      ? pad(updated.getHours()) + ':' + pad(updated.getMinutes()) + ' 更新'
      : '更新时间未知';
  }

  function refreshData() {
    if (refreshScript && refreshScript.parentNode) refreshScript.parentNode.removeChild(refreshScript);
    refreshScript = document.createElement('script');
    refreshScript.src = 'data.js?t=' + new Date().getTime();
    refreshScript.onload = function () { render(window.DASH_DATA); };
    document.body.appendChild(refreshScript);
  }

  updateClock();
  renderBattery();
  render(window.DASH_DATA);
  window.setInterval(updateClock, 30 * 1000);
  window.setInterval(refreshData, REFRESH_MS);
}());
