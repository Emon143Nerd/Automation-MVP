# tests/d-router.ps1 - Milestone D acceptance: every intent lands on a branch.
# Run:  cd F:\Agency\Automation_MVP ;  powershell -ExecutionPolicy Bypass -File .\tests\d-router.ps1
. "$PSScriptRoot\sf-helpers.ps1"                      # WF-01 must be Published (D3)

# A fresh "patient" number per run: avoids the 20-messages-a-day rate limit from
# Milestone B, and keeps old test chatter out of the conversation history.
$patient = New-TestPhone
$owner   = "+15550000001"

$cases = @(
  @{ who=$patient; msg="Can I book a cleaning tomorrow at 2?";            expect="check_availability" },
  @{ who=$patient; msg="Can I come in tomorrow at 10?";                   expect="reply (missing service)" },
  @{ who=$patient; msg="I'd like a cleaning on Friday";                   expect="reply (missing time)" },
  @{ who=$patient; msg="Can I get a cleaning on 1 January 2020 at 10am?"; expect="reply (past_date)" },
  @{ who=$patient; msg="Can I move my appointment to Thursday?";          expect="change_booking" },
  @{ who=$patient; msg="I need to cancel my appointment";                 expect="change_booking" },
  @{ who=$patient; msg="Do you treat children?";                          expect="reply" },
  @{ who=$patient; msg="How much is teeth whitening?";                    expect="reply" },
  @{ who=$patient; msg="Are you open on Saturday?";                       expect="reply" },
  @{ who=$patient; msg="Do you accept insurance?";                        expect="reply" },
  @{ who=(New-TestPhone); msg="Can I talk to a real person please?";       expect="escalate" },
  @{ who=(New-TestPhone); msg="My gum is bleeding and swollen";            expect="escalate (medical)" },
  @{ who=$patient; msg="Please stop sending me messages";                 expect="reply (opt-out hint)" },
  @{ who=$patient; msg="asdf qwerty";                                     expect="reply" },
  @{ who=$owner;   msg="What does tomorrow look like?";                   expect="owner_query" },
  @{ who=$owner;   msg="How many bookings did we get today?";             expect="owner_query" },
  @{ who=$owner;   msg="Find Test Patient's phone number";                expect="owner_query" }
)

$rows = foreach ($c in $cases) {
  try {
    $r = Send-SFRaw $c.who $c.msg
    $reply = [string]$r.reply_text
    [pscustomobject]@{
      Message = $c.msg.Substring(0, [Math]::Min(38, $c.msg.Length))
      Role    = $r.actor_role
      Intent  = $r.ai.intent
      Route   = $r.ai.route
      Reason  = $r.ai.reason_code
      Expect  = $c.expect
      Reply   = $reply.Substring(0, [Math]::Min(60, $reply.Length))
    }
  } catch {
    [pscustomobject]@{ Message = $c.msg; Route = "HTTP ERROR"; Reply = $_.Exception.Message }
  }
  Start-Sleep -Seconds 5      # stay under the free tier's requests-per-minute
}
$rows | Format-Table -AutoSize -Wrap
Write-Host "Test patient used: $patient"
# The two escalate rows use their own numbers: from Milestone F on, escalating pauses
# that patient for 12 h, which would block every later row for the same number.
