source .env
MESSAGE='dio cane'
echo "curl -s -X POST https://api.telegram.org/bot$CONFIG_BOT_TOKEN/sendMessage -d chat_id=$CONFIG_CHATID -d text=\"$MESSAGE\""