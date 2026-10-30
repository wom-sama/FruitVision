# FruitVision mobile client

## Platform
Android app built with Flutter, client-server mode.

## Confirmed users and scope
Exactly Admin, Producer (Nhà sản xuất), Trader (Thương lái), Consumer (Người tiêu dùng). Registration selects only three business roles; all require approval. Pending users can browse public posts and track their own application. NeedsInformation/Rejected users can resubmit. Admin reviews and manages account status. No role is selected on login: the API is the authority.

## Current task
Working APK for signup, login, MFA challenge, approval/resubmission and four role workspaces, with authenticated server-side image/video detection/counting and foreground SignalR chat/job updates. The actual PC backend now reports aiReady=true after verified inference setup. Images/videos are streamed through HTTPS; previews/results come from the owned job API. All approved roles can use AI. Use actual backend seed via HTTPS; no fake operational statistics, ordering, inventory or AI results. Old offline app is preserved separately as historical source.

Counts must distinguish visible objects, confirmed geometric tracks and one-time track line crossings; none implies calibrated kilograms or guaranteed physical unique count. Unknown fruit/stages abstain. Camera action currently captures a still image through the system camera; continuous live camera streaming is not implemented. Background push notifications, real inventory, orders and payments remain outside this slice. This is a noncommercial course demo with inherited model/source licenses, not field-qualified ripeness or food safety.

## Constraints
Phone contains no model or inference engine. Only HTTPS API calls. Secrets encrypted with Android Keystore; no raw token logging or JWT decoding. Server URL can be changed because the user chose a temporary tunnel. Layout must support Vietnamese text, keyboard, narrow phones, 48dp touch controls and useful loading/error states. Visible sample data is backend seed, not proof of completed stock/payment workflows.
