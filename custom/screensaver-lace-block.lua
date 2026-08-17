            -- [custom] 花边双层边框 + 宽度随文本自适应(替换原 InfoMessage 方案)
            local TextWidget = require("ui/widget/textwidget")
            local IconWidget = require("ui/widget/iconwidget")
            local FrameContainer = require("ui/widget/container/framecontainer")
            local HorizontalGroup = require("ui/widget/horizontalgroup")
            local HorizontalSpan = require("ui/widget/horizontalspan")
            local Size = require("ui/size")
            local msg_face = Font:getFace("infofont")
            local msg_text = TextWidget:new{ text = screensaver_message, face = msg_face }
            local max_msg_w = math.floor(Screen:getWidth() * 2/3)
            if msg_text:getSize().w > max_msg_w then
                msg_text = TextBoxWidget:new{ text = screensaver_message, face = msg_face, width = max_msg_w }
            end
            content_widget = FrameContainer:new{
                background = Blitbuffer.COLOR_WHITE,
                bordersize = 2,
                radius = Size.radius.window,
                padding = 2,
                FrameContainer:new{
                    background = Blitbuffer.COLOR_WHITE,
                    bordersize = 1,
                    radius = Size.radius.window,
                    HorizontalGroup:new{
                        align = "center",
                        IconWidget:new{ icon = "notice-heart" },
                        HorizontalSpan:new{ width = Size.span.horizontal_default },
                        msg_text,
                    },
                },
            }
