<?php

/**
 * §8's two dates against the football calendar — the check the settings layer cannot make.
 *
 * `setting_value_check()` sees one value at a time and `update_setting()` refuses a narrow
 * date after a close date; neither can see the SEASON, and §8 says `buyback_closes_on` should
 * fall before conference-championship week.
 *
 * WARNINGS, NEVER REFUSALS, which is why this is separate from the ordering guard: a league
 * is configured before its schedule has synced, so a check with no data must say nothing
 * rather than block.
 *
 * Pure: dates in, problems out. Every input is a 'Y-m-d' string already resolved in the
 * league's own zone by the caller, so this has no opinion about timezones.
 *
 * $s keys:
 *   narrows          'Y-m-d' or '' — buyback_narrows_on
 *   closes           'Y-m-d' or '' — buyback_closes_on
 *   today            'Y-m-d' in the league's zone
 *   championships    'Y-m-d' on or after which a date is too late — conference-championship
 *                    week. NOT read from the cached schedule: the sync only caches
 *                    PP_SCHEDULE_LOOKAHEAD_WEEKS ahead, so the last cached game is the last
 *                    game SO FAR, and at SETUP there is no schedule at all. The caller
 *                    derives this from the calendar.
 *   season_started   bool; both dates freeze at the first pick, so a warning about setting
 *                    one is only actionable before that.
 *
 * Returns a list of ['key' => string, 'text' => string], empty when nothing is wrong.
 */
function decide_calendar_warnings(array $s): array
{
    $narrows = trim((string) ($s['narrows'] ?? ''));
    $closes  = trim((string) ($s['closes'] ?? ''));
    $today   = (string) ($s['today'] ?? '');
    $champs  = $s['championships'] ?? null;
    $started = (bool) ($s['season_started'] ?? false);

    $out = [];

    // §8 RECOMMENDS this date and does not require it (Q37, ruled by Spencer), so the wording
    // offers a consequence rather than reporting a breach.
    if ($closes !== '' && $champs !== null && $closes >= $champs) {
        $out[] = ['key' => 'closes_after_championships', 'text' =>
            'The House is set to stop buying on ' . $closes . ', which is not before conference '
            . 'championship week (around ' . $champs . '). §8 recommends an earlier date so '
            . 'owners go into those games committed to their roster; as set, the exit stays '
            . 'open through the weekend that decides the playoff field. That is yours to '
            . 'choose — nothing is blocked either way.'];
    }

    // A date already gone means the season BEGINS narrowed or closed. Both freeze at the
    // first pick, so this is only worth saying while it can be changed.
    if (!$started) {
        foreach ([['narrows', $narrows, 'narrow to the top 12'],
                  ['closes', $closes, 'stop buying']] as [$key, $date, $what]) {
            if ($date !== '' && $today !== '' && $date <= $today) {
                $out[] = ['key' => $key . '_already_passed', 'text' =>
                    "The date the House will {$what} ({$date}) has already passed, so the season "
                    . 'would begin with it in force. Both dates freeze at the first draft pick.'];
            }
        }
    }

    return $out;
}

/**
 * HOW FAR THROUGH THE SEASON, as a fraction of the milestone bar (0 … 1).
 *
 * `done / segments` puts one milestone reached exactly ON the second dot of a four-dot bar,
 * reporting an event that has not happened. The fill must reach the dot of the LAST COMPLETED
 * milestone, which is `done - 1` segments.
 *
 * The current segment then interpolates, or the bar does not move at all across the gap
 * between the draft and the committee's first poll — most of the regular season:
 *
 *   · BY DATE, when both ends are dated — the poll that landed, the Commissioner's close
 *     date, the last regular-season kickoff. Exact.
 *   · BY WEEK, for the one segment that cannot be dated: nobody knows when the committee
 *     will first publish, so the draft → CFP stretch is measured against $cfpWeek, the week
 *     the committee conventionally starts. An estimate, and the only one here.
 *
 * IT NEVER REACHES THE NEXT DOT. A dot means "this happened", so the interpolation is capped
 * short of it — an estimate that arrives early would say the CFP poll had landed when the
 * committee had not met.
 *
 * $marks: the milestones in order, each ['key', 'done' => bool, 'on' => 'Y-m-d'|null].
 */
function decide_season_progress(array $marks, string $today, ?int $week, int $cfpWeek): float
{
    $n = count($marks);
    $segments = max(1, $n - 1);
    $done = 0;
    foreach ($marks as $m) {
        if (!empty($m['done'])) {
            $done++;
        }
    }
    // Nothing reached yet is the start of the bar; everything reached is the end of it.
    if ($done === 0) {
        return 0.0;
    }
    if ($done >= $n) {
        return 1.0;
    }

    $base = ($done - 1) / $segments;
    $prev = $marks[$done - 1];
    $next = $marks[$done];
    $frac = 0.0;

    if (!empty($prev['on']) && !empty($next['on']) && $next['on'] > $prev['on']) {
        $from = strtotime($prev['on']);
        $to   = strtotime($next['on']);
        $now  = strtotime($today);
        $frac = ($now - $from) / max(1, $to - $from);
    } elseif (($next['key'] ?? '') === 'cfp_pricing' && $week !== null && $cfpWeek > 1) {
        $frac = ($week - 1) / ($cfpWeek - 1);
    }

    // Short of the next dot, and never behind the one already reached.
    $frac = max(0.0, min(0.92, $frac));

    return $base + $frac / $segments;
}
