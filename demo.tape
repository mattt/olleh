Output demo.gif

Set Margin 16
Set MarginFill "#062619"
Set BorderRadius 0

Set FontSize 24
Set Width 1200
Set Height 800

Sleep 500ms

Type@100ms "olleh run"
Sleep 1s
Enter

Sleep 2s

Type@50ms "Say 'hello' in ten different languages"

Enter

# Wait for the response
Wait+Line@10s  />>>/
Sleep 10s
