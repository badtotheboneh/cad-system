local rms_module = {}

local imgui = require 'mimgui'
local ffi = require 'ffi'
local vkeys = require 'vkeys'

local rms_message_queue = {}

local core, log, settings, safe_copy, log_levels, websocket, json, events

local recordsState

local function escape_percents(text)
    if type(text) ~= 'string' then
        return '' 
    end
    local new_text, _ = text:gsub("%%", "%%%%") 
    return new_text 
end

local dashboardState = {
    stats = {},
    recent_activity = {},
    my_latest_reports = {},
    data_loaded = false
}

local function requestReportsList()
    if not websocket or not websocket.is_connected() then
        log('RMS', log_levels.WARN, 'Cannot request reports, websocket not connected.')
        return
    end
    log('RMS', log_levels.INFO, 'Requesting reports list from server...')
    local request = {
        type = 'rms',
        action = 'get_reports',
        token = core.auth_token
    }
    websocket.send(request)
end

local function requestReportDetails(record)
    if not record or not record.record_type or not record.record_id then return end 
    if not websocket or not websocket.is_connected() then
        log('RMS', log_levels.WARN, 'Cannot request report details, websocket not connected.')
        return
    end
    log('RMS', log_levels.INFO, string.format('Requesting details for %s report #%d', record.record_type, record.record_id)) 
    local request = {
        type = 'rms',
        action = 'get_report_details',
        token = core.auth_token,
        payload = {
            reportType = record.record_type,
            recordId = record.record_id 
        }
    }
    websocket.send(request)
end


local function sendReportToServer(reportType, data)
    if not websocket or not websocket.is_connected() then
        log('RMS', log_levels.ERROR, 'Cannot save report, websocket not connected.')
        
        return
    end
    log('RMS', log_levels.INFO, string.format('Sending new %s report to server...', reportType))
    local request = {
        type = 'rms',
        action = 'create_report',
        token = core.auth_token,
        payload = {
            reportType = reportType,
            data = data
        }
    }
    websocket.send(request)
    switchRMSForm(nil) 
end


local function processReportsAsync(payload)
    log('RMS', log_levels.INFO, 'Starting asynchronous processing of ' .. #payload .. ' reports.')
    local formatted_records = {}
    
    local CHUNK_SIZE = 25 

    for i, record in ipairs(payload) do
        
        local person_info = record.primary_person or "N/A"
        if record.secondary_info and record.secondary_info ~= "" then
            person_info = person_info .. " / " .. record.secondary_info
        end
        
        
        record.display_name = string.format("%s - %s (%s)", record.record_type, record.dr_no, person_info)
        record.persons = person_info 

        table.insert(formatted_records, record)

        
        if i % CHUNK_SIZE == 0 then
            log('RMS', log_levels.DEBUG, string.format('Processed report chunk %d/%d', i, #payload))
            wait(0) 
        end
    end
    
    recordsState.records = formatted_records 
    recordsState.data_loaded = true
    log('RMS', log_levels.INFO, 'Successfully loaded and formatted ' .. #recordsState.records .. ' reports asynchronously.')
    events.trigger('rms:reports_loaded')
end

local function process_rms_message(decoded_message)
    if not decoded_message or decoded_message.type ~= 'rms_response' then
        return
    end

    log('RMS', log_levels.INFO, 'Received RMS response from server, action: ' .. (decoded_message.action or 'unknown'))

    if decoded_message.action == 'get_reports' then
        if decoded_message.success and decoded_message.payload then
            log('RMS', log_levels.INFO, 'Received ' .. #decoded_message.payload .. ' reports. Starting async processing.')
            recordsState.data_loaded = false 
            
            lua_thread.create(processReportsAsync, decoded_message.payload)
        else
            log('RMS', log_levels.ERROR, 'Failed to get reports: ' .. (decoded_message.error or 'Unknown error'))
            recordsState.data_loaded = false
        end
    elseif decoded_message.action == 'get_dashboard_data' then
        if decoded_message.success and decoded_message.payload then
            dashboardState.stats = decoded_message.payload.stats or {}
            dashboardState.recent_activity = decoded_message.payload.recent_activity or {}
            dashboardState.my_latest_reports = decoded_message.payload.my_latest_reports or {} 
            dashboardState.data_loaded = true
            log('RMS', log_levels.INFO, 'Successfully loaded dashboard data.')
        else
            log('RMS', log_levels.ERROR, 'Failed to get dashboard data: ' .. (decoded_message.error or 'Unknown error'))
            dashboardState.data_loaded = false
        end
    elseif decoded_message.action == 'get_report_details' then
        if decoded_message.success and decoded_message.payload then
            
            if recordsState.selected_record_item and recordsState.selected_record_item.record_id == decoded_message.payload.id then
                recordsState.selected_record_item.data = decoded_message.payload
                log('RMS', log_levels.INFO, 'Successfully loaded details for item #' .. recordsState.selected_record_item.record_id .. ' in folder.')

                
                if recordsState.selected_record and recordsState.selected_record.items then
                    for i, item in ipairs(recordsState.selected_record.items) do
                        if item.record_id == recordsState.selected_record_item.record_id then
                            recordsState.selected_record.items[i].data = decoded_message.payload
                            break
                        end
                    end
                end
                
            
            elseif recordsState.selected_record and recordsState.selected_record.record_id == decoded_message.payload.id then
                recordsState.selected_record.data = decoded_message.payload
                
                
                for i, record in ipairs(recordsState.records) do
                    if record.record_id == recordsState.selected_record.record_id and record.record_type == recordsState.selected_record.record_type then
                        recordsState.records[i].data = decoded_message.payload
                        log('RMS', log_levels.INFO, 'Successfully loaded details for report #' .. record.record_id)
                        break
                    end
                end
            end
        else
            log('RMS', log_levels.ERROR, 'Failed to get report details: ' .. (decoded_message.error or 'Unknown error'))
        end
    end
end

local active_codebook_view = nil
local penal_search_query = imgui.new.char[128]('')
local traffic_search_query = imgui.new.char[128]('')

local penal_code_data = {
    
    { code = "PC 101", description = "Запугивание, шантаж; Угрозы причинения физического вреда или убийства с целью вызвать страх.", class = "Felony" },
    { code = "PC 102", description = "Нанесение побоев; Умышленное причинение физической боли без вреда для здоровья.", class = "Misdemeanor" },
    { code = "PC 103", description = "Побои с отягчающими обстоятельствами; Нанесение побоев, повлекшее вред здоровью, или с использованием оружия.", class = "Felony" },
    { code = "PC 104", description = "Покушение на убийство; Преднамеренная попытка лишить жизни человека, не доведенная до конца.", class = "Felony" },
    { code = "PC 105", description = "Убийство; Умышленное лишение жизни человека.", class = "Felony" },
    { code = "PC 106", description = "Непредумышленное убийство; Причинение смерти по неосторожности.", class = "Felony" },
    { code = "PC 107", description = "Захват заложников; Незаконное лишение свободы человека против его воли.", class = "Felony" },
    { code = "PC 108", description = "Истязание, пытка; Умышленное причинение сильной боли и страданий.", class = "Felony" },
    { code = "PC 109", description = "Рэкет; Преступная деятельность в составе организованной группы (вымогательство, взяточничество).", class = "Felony" },
    { code = "PC 110", description = "Превышение мер самообороны; Причинение чрезмерного вреда при защите.", class = "Felony" },
    { code = "PC 111", description = "Доведение до суицида; Доведение лица до самоубийства путем угроз или унижения.", class = "Felony" },

    
    { code = "PC 201", description = "Поджог; Умышленное или неосторожное уничтожение имущества огнем.", class = "Felony" },
    { code = "PC 202", description = "Незаконное проникновение на частную территорию; Вход на частную собственность без разрешения.", class = "Misdemeanor" },
    { code = "PC 203", description = "Проникновение на особо охраняемую территорию; Проникновение на закрытый правительственный объект.", class = "Misdemeanor" },
    { code = "PC 204", description = "Кража со взломом; Проникновение в помещение с намерением совершить кражу.", class = "Felony" },
    { code = "PC 205", description = "Грабеж; Открытое хищение имущества, в том числе с применением насилия.", class = "Felony" },
    { code = "PC 206", description = "Вооруженное ограбление; Грабеж с использованием огнестрельного оружия.", class = "Felony" },
    { code = "PC 207", description = "Кража; Тайное хищение чужого имущества.", class = "Felony/Misdemeanor" },
    { code = "PC 208", description = "Кража автотранспортного средства; Угон или незаконное управление автомобилем.", class = "Felony" },
    { code = "PC 209", description = "Кража огнестрельного оружия; Хищение огнестрельного оружия.", class = "Felony" },
    { code = "PC 210", description = "Приобретение имущества, заведомо добытого преступным путем; Покупка или получение краденого.", class = "Misdemeanor" },
    { code = "PC 211", description = "Вымогательство; Требование передачи имущества под угрозой.", class = "Felony" },
    { code = "PC 212", description = "Подлог; Подделка официальных документов.", class = "Misdemeanor" },
    { code = "PC 213", description = "Мошенничество; Хищение имущества путем обмана или злоупотребления доверием.", class = "Felony" },
    { code = "PC 214", description = "Вандализм; Умышленное повреждение или уничтожение чужого имущества.", class = "Misdemeanor" },
    { code = "PC 215", description = "Незаконная рубка лесных насаждений; Вырубка деревьев без разрешения.", class = "Misdemeanor/Felony" },

    
    { code = "PC 301", description = "Непристойное поведение в общественных местах; Демонстрация непристойного поведения или домогательства.", class = "Misdemeanor" },
    { code = "PC 302", description = "Обнажение в общественном месте; Демонстрация наготы в публичных местах.", class = "Misdemeanor" },
    { code = "PC 303", description = "Угроза сексуальным насилием; Угрозы совершения сексуального акта без согласия.", class = "Misdemeanor" },
    { code = "PC 304", description = "Изнасилование; Совершение полового акта с применением насилия.", class = "Felony" },
    { code = "PC 305", description = "Педофилия; Сексуальные действия в отношении несовершеннолетних.", class = "Felony" },
    { code = "PC 306", description = "Нарушение авторских прав; Присвоение чужого авторства с причинением ущерба.", class = "Misdemeanor" },
    { code = "PC 307", description = "Воспрепятствование деятельности журналистов; Создание помех законной работе журналиста.", class = "Felony" },
    { code = "PC 308", description = "Невыплата заработной платы; Умышленная задержка зарплаты работодателем.", class = "Misdemeanor" },
    { code = "PC 309", description = "Нарушение равенства прав и свобод человека; Дискриминация по различным признакам.", class = "Misdemeanor" },
    { code = "PC 310", description = "Организация и участие в азартных играх; Незаконная игорная деятельность.", class = "Misdemeanor" },
    { code = "PC 311", description = "Нарушение права на неприкосновенность частной жизни; Незаконная слежка, прослушивание.", class = "Misdemeanor" },
    { code = "PC 312", description = "Проституция; Оказание сексуальных услуг за вознаграждение.", class = "Felony" },
    { code = "PC 313", description = "Сутенерство; Получение выгоды от занятия проституцией другими лицами.", class = "Felony" },

    
    { code = "PC 401", description = "Взяточничество; Дача или получение взятки должностным лицом.", class = "Felony" },
    { code = "PC 402", description = "Уклонение от уплаты штрафа; Неуплата назначенного штрафа в срок.", class = "Misdemeanor" },
    { code = "PC 403", description = "Неуважение к суду; Оскорбление суда или неисполнение его решений.", class = "Misdemeanor" },
    { code = "PC 404", description = "Неуважение к законодательному органу; Нарушение порядка работы законодательного органа.", class = "Misdemeanor" },
    { code = "PC 406", description = "Нарушение права на обращение в суд; Воспрепятствование даче показаний путем угроз.", class = "Felony" },
    { code = "PC 407", description = "Дезинформация государственного служащего; Предоставление ложных сведений должностному лицу.", class = "Misdemeanor" },
    { code = "PC 408", description = "Дача заведомо ложных показаний; Лжесвидетельство под присягой.", class = "Felony" },
    { code = "PC 409", description = "Уклонение от идентификации себя офицеру полиции; Отказ предоставить документы для установления личности.", class = "Misdemeanor" },
    { code = "PC 410", description = "Выдача себя за государственного служащего; Незаконное присвоение полномочий должностного лица.", class = "Misdemeanor" },
    { code = "PC 411", description = "Выдача себя за адвоката; Незаконное осуществление адвокатской деятельности.", class = "Misdemeanor" },
    { code = "PC 412", description = "Воспрепятствование деятельности государственного служащего; Создание помех законным действиям госслужащего.", class = "Misdemeanor" },
    { code = "PC 413", description = "Сопротивление офицеру полиции; Физическое сопротивление при задержании.", class = "Misdemeanor" },
    { code = "PC 414", description = "Побег из-под стражи; Побег после законного задержания.", class = "Felony" },
    { code = "PC 415", description = "Побег; Побег из места лишения свободы.", class = "Felony" },
    { code = "PC 416", description = "Пособничество в побеге; Содействие побегу заключенного.", class = "Felony" },
    { code = "PC 417", description = "Торговля людьми; Эксплуатация людей с целью принудительного труда или сексуальной торговли.", class = "Felony" },
    { code = "PC 418", description = "Использование государственной телефонной линии не по назначению; Ложные вызовы в экстренные службы.", class = "Misdemeanor" },
    { code = "PC 419", description = "Подделка доказательств; Уничтожение или фальсификация улик.", class = "Felony" },
    { code = "PC 420", description = "Контрабанда; Передача запрещенных предметов в места лишения свободы.", class = "Felony" },
    { code = "PC 422", description = "Нарушение или неисполнение судебного постановления или приказа; Неисполнение решения суда.", class = "Felony" },
    { code = "PC 423", description = "Нарушение или неисполнение судебного акта по гражданскому делу; Злостное неисполнение решения суда по гражданскому делу.", class = "Felony" },
    { code = "PC 424", description = "Уклонение от рассмотрения адвокатского запроса; Игнорирование запроса адвоката должностным лицом.", class = "Misdemeanor" },

    
    { code = "PC 501", description = "Нарушение общественного порядка; Действия, создающие опасность для окружающих.", class = "Misdemeanor" },
    { code = "PC 502", description = "Незаконные протесты или митинги; Организация несогласованных массовых мероприятий.", class = "Misdemeanor" },
    { code = "PC 503", description = "Незаконное осуществление ареста/судебного слушания; Самосуд.", class = "Felony" },
    { code = "PC 504", description = "Государственный переворот; Попытка свержения действующей власти.", class = "Felony" },

    
    { code = "PC 601", description = "Незаконное хранение наркотических веществ; Хранение запрещенных веществ без разрешения.", class = "Felony/Misdemeanor" },
    { code = "PC 602", description = "Производство наркотических веществ; Изготовление или синтез запрещенных препаратов.", class = "Felony" },
    { code = "PC 603", description = "Торговля наркотическими веществами; Сбыт или распространение запрещенных препаратов.", class = "Felony" },
    { code = "PC 604", description = "Употребление алкоголя в общественном месте; Распитие спиртных напитков в публичных местах.", class = "Misdemeanor" },
    { code = "PC 605", description = "Пребывание в состоянии опьянения в общественном месте; Появление в нетрезвом виде, оскорбляющем человеческое достоинство.", class = "Misdemeanor" },
    { code = "PC 606", description = "Незаконное употребление наркотических веществ; Употребление запрещенных препаратов.", class = "Misdemeanor" },
    { code = "PC 607", description = "Намеренное сокрытие личности; Использование маски для сокрытия лица при совершении правонарушения.", class = "Misdemeanor" },
    { code = "PC 608", description = "Терроризм; Совершение действий, устрашающих население и создающих опасность гибели человека.", class = "Felony" },
    { code = "PC 609", description = "Организация преступного сообщества; Создание или участие в организованной преступной группе.", class = "Felony" },
    { code = "PC 610", description = "Воспрепятствование оказанию медицинской помощи; Создание помех для оказания помощи больному или пострадавшему.", class = "Felony/Misdemeanor" },

    
    { code = "PC 701", description = "Жестокое обращение с животными; Причинение боли или страданий животному.", class = "Felony" },
    { code = "PC 702", description = "Жестокое обращение с детьми; Нанесение телесных повреждений ребенку.", class = "Felony" },
    { code = "PC 703", description = "Продажа алкогольных напитков несовершеннолетнему лицу; Продажа алкоголя лицам до 18 лет.", class = "Misdemeanor" },
    { code = "PC 704", description = "Распитие алкогольных напитков несовершеннолетними лицами; Употребление алкоголя лицами до 18 лет.", class = "Misdemeanor" },
    { code = "PC 705", description = "Браконьерство, незаконная охота; Охота без соответствующего разрешения.", class = "Felony/Misdemeanor" },

    
    { code = "PC 801", description = "Хранение лезвия в качестве оружия; Ношение холодного оружия, превышающего установленную длину.", class = "Misdemeanor" },
    { code = "PC 802", description = "Незаконное хранение огнестрельного оружия; Владение оружием без лицензии.", class = "Felony" },
    { code = "PC 803", description = "Незаконное хранение огнестрельного оружия с модификациями; Владение модифицированным оружием.", class = "Felony" },
    { code = "PC 804", description = "Незаконное владение крупнокалиберным огнестрельным оружием; Владение оружием высокой мощности.", class = "Felony" },
    { code = "PC 805", description = "Незаконное осуществление торговли огнестрельным оружием; Продажа оружия без лицензии.", class = "Felony" },
    { code = "PC 806", description = "Незаконное использование огнестрельного оружия; Применение оружия без законных оснований.", class = "Felony" },
    { code = "PC 807", description = "Хранение взрывчатых устройств; Владение взрывчатыми веществами или устройствами.", class = "Felony" },
    { code = "PC 808", description = "Производство запрещенных устройств/оборудований; Изготовление оружия или взрывчатки.", class = "Felony" },
    { code = "PC 809", description = "Владение взрывными устройствами с целью продажи или сбыта; Хранение взрывчатки для продажи.", class = "Felony" },

    
    { code = "PC 901", description = "Уклонение от уплаты налогов; Преднамеренная неуплата налогов.", class = "Felony" },
    { code = "PC 902", description = "Отмывание денег; Легализация доходов, полученных преступным путем.", class = "Felony" },
    { code = "PC 903", description = "Преступления в сфере медицины; Незаконная врачебная практика или халатность.", class = "Felony" },
    { code = "PC 904", description = "Преступление в сфере лицензированной деятельности; Осуществление деятельности без лицензии.", class = "Felony" },
    { code = "PC 905", description = "Незаконное осуществление оперативных мероприятий; Незаконная слежка или прослушивание.", class = "Felony" },
    { code = "PC 906", description = "Фальсификация итогов голосования; Искажение результатов выборов.", class = "Felony" },
    { code = "PC 907", description = "Нарушения при исполнении служебных обязанностей; Халатность или злоупотребление со стороны сотрудника исполнительной власти.", class = "Felony" },
    { code = "PC 908", description = "Нарушения среди государственных служащих; Действия госслужащего, противоречащие интересам службы.", class = "Felony" },
    { code = "PC 909", description = "Провокация к бунту; Подстрекательство к массовым беспорядкам.", class = "Felony" },
    { code = "PC 910", description = "Подкуп электората; Подкуп избирателей во время выборов.", class = "Felony" },
    { code = "PC 911", description = "Превышение власти или должностных полномочий; Использование служебного положения в личных целях.", class = "Felony" },
    { code = "PC 912", description = "Экстремизм, межидеологическая рознь; Разжигание ненависти или вражды.", class = "Felony" },
    { code = "PC 913", description = "Шпионаж; Передача секретных сведений иностранному государству.", class = "Felony" },
    { code = "PC 914", description = "Фальшивомонетничество; Изготовление или сбыт поддельных денег.", class = "Felony" },
}

local traffic_code_data = {
    
    { code = "VC 101(A)", description = "Управление, перемещение или стоянка на дороге общего пользования транспортного средства, не зарегистрированного в штате.", class = "Infraction", fine = "$10,000" },
    { code = "VC 101(B)", description = "Управление транспортным средством без государственного регистрационного знака.", class = "Infraction", fine = "$5,000" },

    { code = "VC 201(A)", description = "Управление транспортным средством без водительской лицензии, либо с отозванной лицензией.", class = "Infraction", fine = "$6,000" },
    { code = "VC 201(B)", description = "Управление транспортным средством лицом, не имеющим при себе действующего водительского удостоверения.", class = "Infraction", fine = "$5,000" },
    { code = "VC 202(A)", description = "Лицо в возрасте от 16 до 18 лет, не прошедшее утвержденный штатом курс вождения.", class = "Infraction", fine = "$5,000" },
    { code = "VC 202(B)", description = "Лицо в возрасте от 16 до 18 лет, управляющее транспортным средством без сопровождения взрослого.", class = "Infraction", fine = "$2,500" },

    { code = "VC 301(A)", description = "Любое лицо, управляющее транспортным средством на любой дороге в пределах города и округа со скоростью более 50 миль в час.", class = "Infraction", fine = "$5,000" },
    { code = "VC 301(B)", description = "Любое лицо, управляющее транспортным средством на любой дороге за городом или округом со скоростью более 70 миль в час.", class = "Infraction", fine = "$7,500" },
    { code = "VC 301(C)", description = "Любое лицо, управляющее транспортным средством на любом шоссе, автомагистрали, трассе штата со скоростью более 90 миль в час.", class = "Infraction", fine = "$10,000" },
    { code = "VC 302(A)", description = "Нарушение правила «помеха справа» или игнорирование приоритета транспортного средства, уже находящегося на перекрёстке.", class = "Infraction", fine = "$5,000" },
    { code = "VC 303(A)", description = "Невыполнение требования уступить дорогу и съехать к правому краю при приближении спецтранспорта со включенными красными и/или синими проблесковыми маячками и сиреной.", class = "Infraction", fine = "$15,000" },
    { code = "VC 304(A)", description = "Игнорирование дорожных знаков, стоп-линий, разметки (пешеходные переходы), указаний сотрудника полиции или регулировщика.", class = "Infraction", fine = "$10,000" },
    { code = "VC 305(A)", description = "Неправильная парковка.", class = "Infraction", fine = "$5,000" },
    { code = "VC 306(A)", description = "Эксплуатация транспортного средства с чрезмерным уровнем шума (включая нештатные выхлопные системы, злоупотребление гудком или сиреной без уважительной причины).", class = "Infraction", fine = "$3,000" },
    { code = "VC 307(A)", description = "Лицо, использующее велосипед или другое самоходное транспортное средство таким образом, что это препятствует движению транспорта, провоцирует беспорядки, создает опасность или демонстрирует потенциальную опасность.", class = "Infraction", fine = "$5,000" },
    { code = "VC 308(A)", description = "Переход дороги вне пешеходного перехода между перекрестками со светофорами или регулировщиками.", class = "Infraction", fine = "$3,000" },
    { code = "VC 309(A)", description = "Лицо, участвующее в уличных гонках (стритрейсинг) или несанкционированных демонстрациях (тейк-овер) на любой общественной дороге.", class = "Infraction", fine = "$30,000" },

    { code = "VC 401(A)", description = "Наличие тонирующих пленок, наклеек или иных светопрепятствующих материалов на лобовом, боковых или заднем стекле транспортного средства.", class = "Infraction", fine = "$7,500" },
    { code = "VC 402(A)", description = "Управление транспортным средством в тёмное время суток либо при недостаточной видимости (дождь, туман, снегопад) с выключенными фарами.", class = "Infraction", fine = "$5,000" },
    { code = "VC 403(A)", description = "Управление транспортным средством на любой из следующих неисправностей на любой дороге общего пользования.", class = "Infraction", fine = "$10,000" },
    { code = "VC 404(A)", description = "Применение гидравлических систем («хопперов» и т.п.) во время движения на дороге общего пользования.", class = "Infraction", fine = "$10,000" },
    { code = "VC 405(A)", description = "Эксплуатация транспортного средства с установленной системой закиси азота вне автодрома или специально отведенного места.", class = "Infraction", fine = "$10,000" },
    { code = "VC 406(A)", description = "Незаконная модификация транспортного средства.", class = "Infraction", fine = "$15,000" },

    { code = "VC 501(A)", description = "Отсутствие средств индивидуальной защиты; Управление мотоциклом или мопедом без защитного шлема.", class = "Infraction", fine = "$8,000" },
    { code = "VC 501(B)", description = "Отсутствие средств индивидуальной защиты; Управление автомобилем или нахождение в нём без пристегнутого ремня безопасности.", class = "Infraction", fine = "$7,500" },
    { code = "VC 502(A)", description = "Неосторожное управление специальной техникой;.", class = "Infraction", fine = "$7,500" },
    { code = "VC 503(A)", description = "Неосторожное управление транспортным средством повышенной проходимости (монстр-траком).", class = "Infraction", fine = "$15,000" },
    { code = "VC 504(A)", description = "Незаконная перевозка пассажиров; .", class = "Infraction", fine = "$5,000" },

    { code = "VC 601(A)", description = "Лицу, превышающему время вождения 8 часов и более, включая остановки для отдыха, без достаточного сна между поездками.", class = "Infraction", fine = "$10,000" },
    { code = "VC 602(A)", description = "Несообщение об опасном грузе в коммерческом или грузовом транспортном средстве.", class = "Infraction", fine = "$10,000" },}


local followReportTypes = { "Follow-up", "Initial Report", "Supplemental" }
local collisionTypes = { "Broadside", "Head-on", "Sideswipe", "Rear-end", "Hit object", "Overturned" }
local weatherConditions = { "Clear", "Cloudy", "Raining", "Fog" }
local roadConditions = { "Dry", "Wet", "Debris" }

local function to_c_array(tbl)
    local c_array = ffi.new("const char*[" .. #tbl .. "]")
    for i, v in ipairs(tbl) do
        c_array[i-1] = v
    end
    return c_array
end

local followReportTypes_c = to_c_array(followReportTypes)
local collisionTypes_c = to_c_array(collisionTypes)
local weatherConditions_c = to_c_array(weatherConditions)
local roadConditions_c = to_c_array(roadConditions)


local UI = {
    rms_window = imgui.new.bool(false),
}
local active_rms_form = nil
local rms_cursor_hotkey = vkeys.VK_F4
local rms_cursor_hotkey_enabled = true
local rms_cursor_force_hidden = false

local function is_rms_context_active()
    return (UI.rms_window and UI.rms_window[0]) or active_rms_form ~= nil or active_codebook_view ~= nil
end

recordsState = {
    filter_index = imgui.new.int(0),
    search_query = imgui.new.char[128](''),
    group_search_query = imgui.new.char[128](''),
    types = { "All", "TCR", "Incident", "Arrest", "FollowUp", "Complaint", "CCWSuspension", "Property" },
    records = {},
    next_record_id = 1,
    selected_record = nil,
    selected_record_item = nil,
    groupingMode = false,
    selectedForGrouping = {},
    isNamingFolder = false
}
local recordsState_types_c = to_c_array(recordsState.types)

local folderNameBuffer = imgui.new.char[128]('New Folder')



local tcrReportBuffers = nil
local followReportBuffers = nil
local arrestRecordBuffers = nil
local incidentReportBuffers = nil
local complaintReportBuffers = nil
local ccwSuspensionBuffers = nil
local propertyReportBuffers = nil

local activeDR = {
    number = imgui.new.char[32](''),
}

local renderRMSWindow
local renderFOLLOWReportWindow
local renderTCRWindow
local renderArrestWindow
local renderIncidentWindow
local renderArrestRecordViewer
local renderPropertyReportViewer

local function requestDashboardData()
    if not websocket or not websocket.is_connected() then
        log('RMS', log_levels.WARN, 'Cannot request dashboard data, websocket not connected.')
        return
    end
    log('RMS', log_levels.INFO, 'Requesting dashboard data from server...')
    local request = {
        type = 'rms',
        action = 'get_dashboard_data',
        token = core.auth_token
    }
    websocket.send(request)
end

local function createTCRBuffers()
    if tcrReportBuffers then return end
    log('RMS', log_levels.INFO, 'Creating TCR form buffers...')
    tcrReportBuffers = {
        location = imgui.new.char[128]('E SLAUSON AV / S SAN PEDRO ST'),
        date = imgui.new.char[32]('06/03/2020'),
        time = imgui.new.char[32]('00:30'),
        reporting_officer = imgui.new.char[64](''),
        officer_id = imgui.new.char[32](''),
        v1_driver_name = imgui.new.char[128](''),
        v1_driver_license = imgui.new.char[64](''),
        v1_vehicle_year_make = imgui.new.char[128](''),
        v1_vehicle_plate = imgui.new.char[64](''),
        v1_insurance = imgui.new.char[128](''),
        v2_driver_name = imgui.new.char[128](''),
        v2_driver_license = imgui.new.char[64](''),
        v2_vehicle_year_make = imgui.new.char[128](''),
        v2_vehicle_plate = imgui.new.char[64](''),
        v2_insurance = imgui.new.char[128](''),
        collision_type = imgui.new.int(0),
        weather_condition = imgui.new.int(0),
        road_condition = imgui.new.int(0),
        narrative = imgui.new.char[2048](''),
        injuries = imgui.new.bool(false),
        towed = imgui.new.bool(false),
        citations_issued = imgui.new.bool(false),
        pcf_factor = imgui.new.char[256]('')
    }
    if core and core.current_user then
        safe_copy(tcrReportBuffers.reporting_officer, core.current_user.full_name or "")
        safe_copy(tcrReportBuffers.officer_id, core.current_user.badge_number or "")
    end
end

local function createFollowUpBuffers()
    if followReportBuffers then return end
    log('RMS', log_levels.INFO, 'Creating Follow-Up Report form buffers...')
    followReportBuffers = {
        report_date = imgui.new.char[32]('2/13/2018'),
        original_report_date = imgui.new.char[32]('2/2/2018'),
        dr_no = imgui.new.char[32](''),
        victim_booked_to = imgui.new.char[64]('Gudino, Pedro'),
        work_folder_id = imgui.new.char[32]('F009-18'),
        narrative_text = imgui.new.char[2048]('CCAD Up-date: Case Status...'),
        reporting_officer = imgui.new.char[64](''),
        officer_serial = imgui.new.char[32](''),
        officer_division = imgui.new.char[32]('FID/CAT'),

        
        selected_report_type = imgui.new('int[1]', 0),
        is_multiple = imgui.new('bool[1]', true),
        case_status = imgui.new('int[1]', 1),
        property_booked = imgui.new('bool[1]', false),
        form_16_08_completed = imgui.new('bool[1]', false),

        persons = {
            {
                s_type = imgui.new.char[4]('S'), sex = imgui.new.char[4]('M'), desc = imgui.new.char[4]('H'),
                hair = imgui.new.char[8]('BLK'), eyes = imgui.new.char[8]('BRO'), height = imgui.new.char[8]('602'),
                weight = imgui.new.char[8]('202'), dob = imgui.new.char[16]('9/23/1983'), age = imgui.new.char[8]('34'),
                name_address = imgui.new.char[128]('Gudino, Pedro  |  Attempt Murder, ADW on P.O.'),
                action_taken = imgui.new.char[128]('DA Filed. 564/187, 245PC ADW, Fel in Poss Gun')
            },
            {
                s_type = imgui.new.char[4](''), sex = imgui.new.char[4](''), desc = imgui.new.char[4](''),
                hair = imgui.new.char[8](''), eyes = imgui.new.char[8](''), height = imgui.new.char[8](''),
                weight = imgui.new.char[8](''), dob = imgui.new.char[16](''), age = imgui.new.char[8](''),
                name_address = imgui.new.char[128](''), action_taken = imgui.new.char[128]('')
            }
        }
    }
    if core and core.current_user then
        safe_copy(followReportBuffers.reporting_officer, core.current_user.full_name or "")
        safe_copy(followReportBuffers.officer_serial, core.current_user.badge_number or "")
    end
end

local function createArrestRecordBuffers()
    if arrestRecordBuffers then return end
    log('RMS', log_levels.INFO, 'Creating Arrest Record form buffers...')
    arrestRecordBuffers = {
        dr_no = imgui.new.char[32](''),
        booking_no = imgui.new.char[32](''),
        last_name = imgui.new.char[64](''),
        first_name = imgui.new.char[64](''),
        middle_name = imgui.new.char[64](''),
        sex = imgui.new.char[8](''),
        descent = imgui.new.char[8](''),
        hair = imgui.new.char[8](''),
        eyes = imgui.new.char[8](''),
        height = imgui.new.char[8](''),
        weight = imgui.new.char[8](''),
        dob = imgui.new.char[16](''),
        age = imgui.new.char[8](''),
        moniker = imgui.new.char[64](''),
        location_of_arrest = imgui.new.char[128](''),
        date_arrested = imgui.new.char[16](''),
        time_arrested = imgui.new.char[16](''),
        charge = imgui.new.char[128](''),
        crime_location = imgui.new.char[128](''),
        arresting_officer = imgui.new.char[64](''),
        officer_serial = imgui.new.char[32](''),
        involved_person_name = imgui.new.char[128](''),
        involved_person_details = imgui.new.char[128](''),
        narrative = imgui.new.char[4096](''),
        property_items = {
            {
                quant = imgui.new.char[8]('1'), article = imgui.new.char[64]('Firearm'), brand = imgui.new.char[32]('Glock'), model = imgui.new.char[32]('27'), desc = imgui.new.char[128]('40 cal PISTOL') 
            },
            {
                quant = imgui.new.char[8]('1'), article = imgui.new.char[64]('Magazine(Drum)'), brand = imgui.new.char[32](''), model = imgui.new.char[32](''), desc = imgui.new.char[128]('High capacity drum mag') 
            },
            {
                quant = imgui.new.char[8]('1'), article = imgui.new.char[64]('Live Ammo'), brand = imgui.new.char[32](''), model = imgui.new.char[32](''), desc = imgui.new.char[128]('40 cal') 
            },
            {
                quant = imgui.new.char[8]('1'), article = imgui.new.char[64]('Cellphone'), brand = imgui.new.char[32]('iPhone'), model = imgui.new.char[32](''), desc = imgui.new.char[128]('blk iPhone belongs to Johnson, Keith') 
            }
        }
    }
    if core and core.current_user then
        safe_copy(arrestRecordBuffers.arresting_officer, core.current_user.full_name or "")
        safe_copy(arrestRecordBuffers.officer_serial, core.current_user.badge_number or "")
    end
end

local function createIncidentReportBuffers()
    if incidentReportBuffers then return end
    log('RMS', log_levels.INFO, 'Creating Incident Report form buffers...')
    incidentReportBuffers = {
        dr_no = imgui.new.char[32](''),
        report_date = imgui.new.char[32](''),
        report_time = imgui.new.char[32](''),
        incident_date = imgui.new.char[32](''),
        incident_time = imgui.new.char[32](''),
        location = imgui.new.char[128](''),
        incident_type = imgui.new.char[128](''),
        reporting_officer = imgui.new.char[64](''),
        officer_serial = imgui.new.char[32](''),
        persons = {
            {
                type = imgui.new.char[4]('V'), name = imgui.new.char[128]('Doe, Jane'), dob = imgui.new.char[32]('05/15/1988'), sex = imgui.new.char[8]('F'), desc = imgui.new.char[8]('W'), phone = imgui.new.char[64]('555-0102')
            },
            {
                type = imgui.new.char[4]('S'), name = imgui.new.char[128]('Unknown Male'), dob = imgui.new.char[32]('Approx. 20-25'), sex = imgui.new.char[8]('M'), desc = imgui.new.char[8]('H'), phone = imgui.new.char[64]('N/A')
            },
            {
                type = imgui.new.char[4]('W'), name = imgui.new.char[128]('Smith, John'), dob = imgui.new.char[32]('03/22/1975'), sex = imgui.new.char[8]('M'), desc = imgui.new.char[8]('W'), phone = imgui.new.char[64]('555-0103')
            }
        },
        property = {
            {
                code = imgui.new.char[8]('Stolen'), article = imgui.new.char[128]('Laptop'), description = imgui.new.char[256]('15" MacBook Pro, Silver, S/N: C02XXXXXX'), value = imgui.new.char[32]('1500')
            },
            {
                code = imgui.new.char[8]('Stolen'), article = imgui.new.char[128]('Jewelry'), description = imgui.new.char[256]('Gold necklace with diamond pendant'), value = imgui.new.char[32]('800')
            },
            {
                code = imgui.new.char[8](''), article = imgui.new.char[128](''), description = imgui.new.char[256](''), value = imgui.new.char[32]('')
            }
        },
        modus_operandi = imgui.new.char[512]('Suspect gained entry by smashing a rear window with a rock...'),
        narrative = imgui.new.char[4096]('test'),
        case_status = imgui.new.int(0)
    }
    if core and core.current_user then
        safe_copy(incidentReportBuffers.reporting_officer, core.current_user.full_name or "")
        safe_copy(incidentReportBuffers.officer_serial, core.current_user.badge_number or "")
    end
end

local function createComplaintBuffers()
    if complaintReportBuffers then return end
    log('RMS', log_levels.INFO, 'Creating Complaint Report form buffers...')
    complaintReportBuffers = {
        dr_no = imgui.new.char[32](''),
        
        c_name = imgui.new.char[128](''),
        c_address = imgui.new.char[256](''),
        c_phone = imgui.new.char[64](''),
        c_dob = imgui.new.char[32](''),
        c_sex = imgui.new.char[8](''),
        c_desc = imgui.new.char[8](''),
        
        incident_type = imgui.new.char[128](''),
        incident_date_occurred = imgui.new.char[32](''),
        incident_time_occurred = imgui.new.char[32](''),
        incident_location = imgui.new.char[256](''),
        
        involved_persons = imgui.new.char[1024](''),
        involved_property = imgui.new.char[1024](''),
        
        narrative = imgui.new.char[4096](''),
        
        reporting_officer = imgui.new.char[64](''),
        officer_serial = imgui.new.char[32]('')
    }
    
    
    if core and core.current_user then
        safe_copy(complaintReportBuffers.reporting_officer, core.current_user.full_name or "")
        safe_copy(complaintReportBuffers.officer_serial, core.current_user.badge_number or "")
    end
end

local function createCCWSuspensionBuffers()
    if ccwSuspensionBuffers then return end
    log('RMS', log_levels.INFO, 'Creating CCW Suspension form buffers...')
    ccwSuspensionBuffers = {
        dr_no = imgui.new.char[32](''),
        
        lh_name = imgui.new.char[128](''),
        lh_dob = imgui.new.char[32](''),
        lh_address = imgui.new.char[256](''),
        lh_license_number = imgui.new.char[64](''),
        
        suspension_reason = imgui.new.int(0),
        seizure_date = imgui.new.char[32](''),
        seizure_time = imgui.new.char[32](''),
        seized_firearms = imgui.new.char[1024](''),
        
        related_dr_no = imgui.new.char[32](''),
        incident_summary = imgui.new.char[2048](''),
        
        reporting_officer = imgui.new.char[64](''),
        officer_serial = imgui.new.char[32](''),
        supervisor_signature = imgui.new.bool(false)
    }
    if core and core.current_user then
        safe_copy(ccwSuspensionBuffers.reporting_officer, core.current_user.full_name or "")
        safe_copy(ccwSuspensionBuffers.officer_serial, core.current_user.badge_number or "")
    end
    if ffi.string(activeDR.number) ~= "" then
        ffi.copy(ccwSuspensionBuffers.related_dr_no, activeDR.number, 32)
    end
end

local function createPropertyReportBuffers()
    if propertyReportBuffers then return end
    log('RMS', log_levels.INFO, 'Creating Property Report (16.08) form buffers...')
    propertyReportBuffers = {
        dr_no = imgui.new.char[32](''),
        
        owner_name = imgui.new.char[128](''),
        owner_address = imgui.new.char[256](''),
        owner_phone = imgui.new.char[64](''),

        booking_reason = imgui.new.int(0), 
        
        narrative = imgui.new.char[2048](''),
        
        reporting_officer = imgui.new.char[64](''),
        officer_serial = imgui.new.char[32](''),
        
        
        items = {}
    }
    if core and core.current_user then
        safe_copy(propertyReportBuffers.reporting_officer, core.current_user.full_name or "")
        safe_copy(propertyReportBuffers.officer_serial, core.current_user.badge_number or "")
    end
    for i = 1, 8 do
        table.insert(propertyReportBuffers.items, {
            quant = imgui.new.char[8](''),
            description = imgui.new.char[256](''),
            value = imgui.new.char[32]('')
        })
    end
end

local function destroyTCRBuffers()
    if not tcrReportBuffers then return end
    log('RMS', log_levels.INFO, 'Destroying TCR form buffers...')
    tcrReportBuffers = nil
    collectgarbage()
end

local function destroyFollowUpBuffers()
    if not followReportBuffers then return end
    log('RMS', log_levels.INFO, 'Destroying Follow-Up Report form buffers...')
    followReportBuffers = nil
    collectgarbage()
end

local function destroyArrestRecordBuffers()
    if not arrestRecordBuffers then return end
    log('RMS', log_levels.INFO, 'Destroying Arrest Record form buffers...')
    arrestRecordBuffers = nil
    collectgarbage()
end

local function destroyIncidentReportBuffers()
    if not incidentReportBuffers then return end
    log('RMS', log_levels.INFO, 'Destroying Incident Report form buffers...')
    incidentReportBuffers = nil
    collectgarbage()
end

local function destroyComplaintBuffers()
    if not complaintReportBuffers then return end
    log('RMS', log_levels.INFO, 'Destroying Complaint Report form buffers...')
    complaintReportBuffers = nil
    collectgarbage()
end

local function destroyCCWSuspensionBuffers()
    if not ccwSuspensionBuffers then return end
    log('RMS', log_levels.INFO, 'Destroying CCW Suspension form buffers...')
    ccwSuspensionBuffers = nil
    collectgarbage()
end

local function destroyPropertyReportBuffers()
    if not propertyReportBuffers then return end
    log('RMS', log_levels.INFO, 'Destroying Property Report (16.08) form buffers...')
    propertyReportBuffers = nil
    collectgarbage()
end

switchRMSForm = function(new_form)
    if active_rms_form == new_form then
        new_form = nil
    end

    if active_rms_form == 'TCR' then destroyTCRBuffers()
    elseif active_rms_form == 'FollowUp' then destroyFollowUpBuffers()
    elseif active_rms_form == 'Arrest' then destroyArrestRecordBuffers()
    elseif active_rms_form == 'Incident' then destroyIncidentReportBuffers()
    elseif active_rms_form == 'Complaint' then destroyComplaintBuffers()
    elseif active_rms_form == 'CCWSuspension' then destroyCCWSuspensionBuffers()
    elseif active_rms_form == 'Property' then destroyPropertyReportBuffers()
    end

    if new_form then
        if new_form == 'TCR' then createTCRBuffers()
        elseif new_form == 'FollowUp' then createFollowUpBuffers()
        elseif new_form == 'Arrest' then createArrestRecordBuffers()
        elseif new_form == 'Incident' then createIncidentReportBuffers()
        elseif new_form == 'Complaint' then createComplaintBuffers() 
        elseif new_form == 'CCWSuspension' then createCCWSuspensionBuffers()
        elseif new_form == 'Property' then createPropertyReportBuffers() 
        end
    end
    active_rms_form = new_form
end

local function saveArrestRecord()
    local b = arrestRecordBuffers
    if b == nil then return end

    local record_data = {
        booking_no = ffi.string(b.booking_no),
        last_name = ffi.string(b.last_name),
        first_name = ffi.string(b.first_name),
        middle_name = ffi.string(b.middle_name),
        sex = ffi.string(b.sex),
        descent = ffi.string(b.descent),
        hair = ffi.string(b.hair),
        eyes = ffi.string(b.eyes),
        height = ffi.string(b.height),
        weight = ffi.string(b.weight),
        dob = ffi.string(b.dob),
        age = ffi.string(b.age),
        moniker = ffi.string(b.moniker),
        location_of_arrest = ffi.string(b.location_of_arrest),
        date_arrested = ffi.string(b.date_arrested),
        time_arrested = ffi.string(b.time_arrested),
        charge = ffi.string(b.charge),
        crime_location = ffi.string(b.crime_location),
        reporting_officer = ffi.string(b.arresting_officer), 
        officer_serial = ffi.string(b.officer_serial),
        involved_persons = json.encode({
            name = ffi.string(b.involved_person_name),
            details = ffi.string(b.involved_person_details)
        }),
        narrative = ffi.string(b.narrative),
        property_items = {}
    }

    for _, item in ipairs(b.property_items) do
        if ffi.string(item.article) ~= "" then
            table.insert(record_data.property_items, {
                quant = ffi.string(item.quant),
                article = ffi.string(item.article),
                brand = ffi.string(item.brand),
                model = ffi.string(item.model),
                desc = ffi.string(item.desc)
            })
        end
    end
    record_data.property_items = json.encode(record_data.property_items)

    sendReportToServer("Arrest", record_data)
end

local function saveTCR()
    local b = tcrReportBuffers
    if b == nil then return end

    local record_data = {
        location = ffi.string(b.location),
        date = ffi.string(b.date),
        time = ffi.string(b.time),
        reporting_officer = ffi.string(b.reporting_officer),
        officer_serial = ffi.string(b.officer_id), 
        v1_driver_name = ffi.string(b.v1_driver_name),
        v1_driver_license = ffi.string(b.v1_driver_license),
        v1_vehicle_year_make = ffi.string(b.v1_vehicle_year_make),
        v1_vehicle_plate = ffi.string(b.v1_vehicle_plate),
        v1_insurance = ffi.string(b.v1_insurance),
        v2_driver_name = ffi.string(b.v2_driver_name),
        v2_driver_license = ffi.string(b.v2_driver_license),
        v2_vehicle_year_make = ffi.string(b.v2_vehicle_year_make),
        v2_vehicle_plate = ffi.string(b.v2_vehicle_plate),
        v2_insurance = ffi.string(b.v2_insurance),
        collision_type = collisionTypes[b.collision_type[0] + 1],
        weather_condition = weatherConditions[b.weather_condition[0] + 1],
        road_condition = roadConditions[b.road_condition[0] + 1],
        narrative = ffi.string(b.narrative),
        injuries = b.injuries[0],
        towed = b.towed[0],
        citations_issued = b.citations_issued[0],
        pcf_factor = ffi.string(b.pcf_factor)
    }

    sendReportToServer("TCR", record_data)
end

local function saveFollowUpReport()
    local b = followReportBuffers
    if b == nil then return end

    local persons_data = {}
    for _, person in ipairs(b.persons) do
        if ffi.string(person.name_address) ~= "" then
            table.insert(persons_data, {
                s_type = ffi.string(person.s_type),
                sex = ffi.string(person.sex),
                desc = ffi.string(person.desc),
                hair = ffi.string(person.hair),
                eyes = ffi.string(person.eyes),
                height = ffi.string(person.height),
                weight = ffi.string(person.weight),
                dob = ffi.string(person.dob),
                age = ffi.string(person.age),
                name_address = ffi.string(person.name_address),
                action_taken = ffi.string(person.action_taken)
            })
        end
    end

    local record_data = {
        report_date = ffi.string(b.report_date),
        original_report_date = ffi.string(b.original_report_date),
        original_dr_no = ffi.string(b.dr_no),
        victim_booked_to = ffi.string(b.victim_booked_to),
        work_folder_id = ffi.string(b.work_folder_id),
        narrative = ffi.string(b.narrative_text),
        reporting_officer = ffi.string(b.reporting_officer),
        officer_serial = ffi.string(b.officer_serial),
        officer_division = ffi.string(b.officer_division),
        persons = json.encode(persons_data),

        
        
        selected_report_type = followReportTypes[b.selected_report_type[0] + 1],
        is_multiple = b.is_multiple[0] == true,
        case_status = tonumber(b.case_status[0]),
        property_booked = b.property_booked[0] == true,
        form_16_08_completed = b.form_16_08_completed[0] == true
    }

    sendReportToServer("FollowUp", record_data)
end

local function saveIncidentReport()
    local b = incidentReportBuffers
    if b == nil then return end

    local status_value = b.case_status 
    local case_status_text = "Active" 
    if status_value == 1 then
        case_status_text = "Suspended"
    elseif status_value == 2 then
        case_status_text = "Closed"
    end

    local record_data = {
        report_date = ffi.string(b.report_date),
        report_time = ffi.string(b.report_time),
        incident_date = ffi.string(b.incident_date),
        incident_time = ffi.string(b.incident_time),
        location = ffi.string(b.location),
        incident_type = ffi.string(b.incident_type),
        reporting_officer = ffi.string(b.reporting_officer), 
        officer_serial = ffi.string(b.officer_serial),
        persons = {},
        property = {},
        modus_operandi = ffi.string(b.modus_operandi),
        narrative = ffi.string(b.narrative),
        case_status = case_status_text
    }

    local persons_data = {}
    for _, person in ipairs(b.persons) do
        if ffi.string(person.name) ~= "" then
            table.insert(persons_data, {
                type = ffi.string(person.type), name = ffi.string(person.name),
                dob = ffi.string(person.dob), sex = ffi.string(person.sex),
                desc = ffi.string(person.desc), phone = ffi.string(person.phone)
            })
        end
    end
    record_data.persons = json.encode(persons_data)

    local property_data = {}
    for _, prop in ipairs(b.property) do
        if ffi.string(prop.article) ~= "" then
            table.insert(property_data, {
                code = ffi.string(prop.code), article = ffi.string(prop.article),
                description = ffi.string(prop.description), value = ffi.string(prop.value)
            })
        end
    end
    record_data.property = json.encode(property_data)
    
    sendReportToServer("Incident", record_data)
end

local function saveComplaint()
    local b = complaintReportBuffers
    if b == nil then return end

    local record_data = {
        c_name = ffi.string(b.c_name),
        c_address = ffi.string(b.c_address),
        c_phone = ffi.string(b.c_phone),
        c_dob = ffi.string(b.c_dob),
        c_sex = ffi.string(b.c_sex),
        c_desc = ffi.string(b.c_desc),
        incident_type = ffi.string(b.incident_type),
        incident_date_occurred = ffi.string(b.incident_date_occurred),
        incident_time_occurred = ffi.string(b.incident_time_occurred),
        incident_location = ffi.string(b.incident_location),
        involved_persons = ffi.string(b.involved_persons),
        involved_property = ffi.string(b.involved_property),
        narrative = ffi.string(b.narrative),
        reporting_officer = ffi.string(b.reporting_officer),
        officer_serial = ffi.string(b.officer_serial)
    }
    
    sendReportToServer("Complaint", record_data)
end

local function saveCCWSuspension()
    local b = ccwSuspensionBuffers
    if b == nil then return end

    local suspensionReasons = { "Arrest for Felony/Violent Misdemeanor", "Domestic Violence Incident", "Mental Health Hold (5150)", "Judicial Order/Restraining Order", "Public Safety Concern", "Other" }

    local record_data = {
        lh_name = ffi.string(b.lh_name),
        lh_dob = ffi.string(b.lh_dob),
        lh_address = ffi.string(b.lh_address),
        lh_license_number = ffi.string(b.lh_license_number),
        seizure_date = ffi.string(b.seizure_date),
        seizure_time = ffi.string(b.seizure_time),
        seized_firearms = ffi.string(b.seized_firearms),
        related_dr_no = ffi.string(b.related_dr_no),
        incident_summary = ffi.string(b.incident_summary),
        reporting_officer = ffi.string(b.reporting_officer),
        officer_serial = ffi.string(b.officer_serial),

        
        
        suspension_reason = suspensionReasons[b.suspension_reason[0] + 1],
        supervisor_signature = b.supervisor_signature[0] == true
    }
    
    sendReportToServer("CCWSuspension", record_data)
end

local function savePropertyReport()
    local b = propertyReportBuffers
    if b == nil then return end

    local bookingReasons = { "Evidence", "Found Property", "Safekeeping" }

    local record_data = {
        owner_name = ffi.string(b.owner_name),
        owner_address = ffi.string(b.owner_address),
        owner_phone = ffi.string(b.owner_phone),
        
        booking_reason = bookingReasons[b.booking_reason + 1],
        narrative = ffi.string(b.narrative),
        reporting_officer = ffi.string(b.reporting_officer),
        officer_serial = ffi.string(b.officer_serial),
        items = {}
    }

    for _, item in ipairs(b.items) do
        if ffi.string(item.description) ~= "" then
            table.insert(record_data.items, {
                quant = ffi.string(item.quant),
                description = ffi.string(item.description),
                value = ffi.string(item.value)
            })
        end
    end
    
    sendReportToServer("Property", record_data)
end

renderFollowUpWindow = function()
    if not followReportBuffers then return end
    local p_open = imgui.new.bool(true)
    imgui.SetNextWindowSize(imgui.new('ImVec2', 1400, 700), imgui.Cond.FirstUseEver)

    if imgui.Begin("Follow-Up Report", p_open) then
        local draw_list = imgui.GetWindowDrawList()
        local pos = imgui.GetWindowPos()
        local size = imgui.GetWindowSize()
        draw_list:AddRectFilled(pos, imgui.new('ImVec2', pos.x + size.x, pos.y + size.y), 0xFFFFFFFF)

        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.0, 0.0, 0.0, 1.0))
        imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0.9, 0.9, 0.9, 1.0))
        imgui.PushStyleColor(imgui.Col.CheckMark, imgui.ImVec4(0.4, 0.4, 0.4, 1.0))
        
        local b = followReportBuffers

        imgui.Text('LOS SANTOS POLICE DEPARTMENT - FOLLOW-UP REPORT')
        imgui.SameLine(imgui.GetWindowWidth() - 250)
        imgui.Text('CASE NO. (DR)'); if imgui.IsItemHovered() then imgui.SetTooltip("НОМЕР ДЕЛА (DR)") end
        imgui.SameLine()
        imgui.PushItemWidth(150)
        local potential_dr_no = imgui.new.char[32](string.format("FU%s-%04d", os.date("%y%m"), recordsState.next_record_id))
        imgui.InputText('##DRNO', potential_dr_no, ffi.sizeof(potential_dr_no), imgui.InputTextFlags.ReadOnly)
        if imgui.IsItemHovered() then imgui.SetTooltip("Номер будет присвоен при сохранении") end
        imgui.PopItemWidth()
        imgui.Separator()

        imgui.PushItemWidth(150); imgui.InputText('DATE OF THIS REPORT', b.report_date, ffi.sizeof(b.report_date)); if imgui.IsItemHovered() then imgui.SetTooltip("ДАТА ЭТОГО ОТЧЕТА") end; imgui.PopItemWidth(); imgui.SameLine()
        imgui.PushItemWidth(170); imgui.InputText('ORIGINAL REPORT DATE', b.original_report_date, ffi.sizeof(b.original_report_date)); if imgui.IsItemHovered() then imgui.SetTooltip("ДАТА ИСХОДНОГО РЕПОРТА") end; imgui.PopItemWidth(); imgui.SameLine()
        imgui.PushItemWidth(250); imgui.Combo('ORIGINAL REPORT TYPE', b.selected_report_type, followReportTypes_c, #followReportTypes); if imgui.IsItemHovered() then imgui.SetTooltip("ТИП ИСХОДНОГО РЕПОРТА") end; imgui.PopItemWidth(); imgui.SameLine()
        imgui.Checkbox('MULTIPLE', b.is_multiple); if imgui.IsItemHovered() then imgui.SetTooltip("НЕСКОЛЬКО (Отметьте, если в деле несколько инцидентов)") end

        imgui.PushItemWidth(488); imgui.InputText('VICTIM / PERSON BOOKED', b.victim_booked_to, ffi.sizeof(b.victim_booked_to)); if imgui.IsItemHovered() then imgui.SetTooltip("ПОТЕРПЕВШИЙ / ЗАДЕРЖАННЫЙ") end; imgui.PopItemWidth(); imgui.SameLine()
        imgui.PushItemWidth(150); imgui.InputText('WORK FOLDER I.D.', b.work_folder_id, ffi.sizeof(b.work_folder_id)); if imgui.IsItemHovered() then imgui.SetTooltip("РАБОЧАЯ ПАПКА") end; imgui.PopItemWidth()

        imgui.Separator()
        imgui.Text('CASE STATUS:'); if imgui.IsItemHovered() then imgui.SetTooltip("СТАТУС ДЕЛА:") end
        imgui.SameLine()
        if imgui.Selectable('1 Cleared by Arrest', b.case_status[0] == 1, 0, imgui.new('ImVec2', 170, 0)) then b.case_status[0] = 1 end; if imgui.IsItemHovered() then imgui.SetTooltip("1 Закрыто арестом") end
        imgui.SameLine()
        if imgui.Selectable('2 Cleared Otherwise', b.case_status[0] == 2, 0, imgui.new('ImVec2', 140, 0)) then b.case_status[0] = 2 end; if imgui.IsItemHovered() then imgui.SetTooltip("2 Закрыто иначе") end
        imgui.SameLine()
        if imgui.Selectable('3 Report Unfounded', b.case_status[0] == 3, 0, imgui.new('ImVec2', 170, 0)) then b.case_status[0] = 3 end; if imgui.IsItemHovered() then imgui.SetTooltip("3 Репорт необоснован") end
        imgui.SameLine()
        if imgui.Selectable('4 Investigation Continuing', b.case_status[0] == 4, 0, imgui.new('ImVec2', 220, 0)) then b.case_status[0] = 4 end; if imgui.IsItemHovered() then imgui.SetTooltip("4 Расследование продолжается") end
        imgui.Separator()

        imgui.Columns(11, 'personsColumns', true)
        local col_total_width = imgui.GetWindowWidth()
        imgui.SetColumnWidth(0, 25); imgui.SetColumnWidth(1, 40); imgui.SetColumnWidth(2, 50);
        imgui.SetColumnWidth(3, 50); imgui.SetColumnWidth(4, 50); imgui.SetColumnWidth(5, 60);
        imgui.SetColumnWidth(6, 60); imgui.SetColumnWidth(7, 90); imgui.SetColumnWidth(8, 40);
        local remaining_width = col_total_width - 465
        imgui.SetColumnWidth(9, remaining_width * 0.5)
        imgui.SetColumnWidth(10, remaining_width * 0.5)

        imgui.Text('S'); if imgui.IsItemHovered() then imgui.SetTooltip("Статус (S, V, W)") end; imgui.NextColumn()
        imgui.Text('SEX'); if imgui.IsItemHovered() then imgui.SetTooltip("ПОЛ") end; imgui.NextColumn()
        imgui.Text('DESC'); if imgui.IsItemHovered() then imgui.SetTooltip("РАСА") end; imgui.NextColumn()
        imgui.Text('HAIR'); if imgui.IsItemHovered() then imgui.SetTooltip("ВОЛОСЫ") end; imgui.NextColumn()
        imgui.Text('EYES'); if imgui.IsItemHovered() then imgui.SetTooltip("ГЛАЗА") end; imgui.NextColumn()
        imgui.Text('HGT'); if imgui.IsItemHovered() then imgui.SetTooltip("РОСТ") end; imgui.NextColumn()
        imgui.Text('WGT'); if imgui.IsItemHovered() then imgui.SetTooltip("ВЕС") end; imgui.NextColumn()
        imgui.Text('D.O.B.'); if imgui.IsItemHovered() then imgui.SetTooltip("ДАТА РОЖДЕНИЯ") end; imgui.NextColumn()
        imgui.Text('AGE'); if imgui.IsItemHovered() then imgui.SetTooltip("ЛЕТ") end; imgui.NextColumn()
        imgui.Text('NAME / CHARGE'); if imgui.IsItemHovered() then imgui.SetTooltip("ИМЯ / ОБВИНЕНИЕ") end; imgui.NextColumn()
        imgui.Text('ACTION TAKEN'); if imgui.IsItemHovered() then imgui.SetTooltip("ДЕЙСТВИЯ") end; imgui.NextColumn()
        imgui.Separator()

        for i, person in ipairs(b.persons) do
            imgui.InputText('##s'..i, person.s_type, ffi.sizeof(person.s_type)); if imgui.IsItemHovered() then imgui.SetTooltip("Статус: S-Подозреваемый, V-Жертва, W-Свидетель") end; imgui.NextColumn()
            imgui.InputText('##sex'..i, person.sex, ffi.sizeof(person.sex)); if imgui.IsItemHovered() then imgui.SetTooltip("Пол (M/F)") end; imgui.NextColumn()
            imgui.InputText('##desc'..i, person.desc, ffi.sizeof(person.desc)); if imgui.IsItemHovered() then imgui.SetTooltip("Раса/происхождение (H, W, B, A)") end; imgui.NextColumn()
            imgui.InputText('##hair'..i, person.hair, ffi.sizeof(person.hair)); if imgui.IsItemHovered() then imgui.SetTooltip("Цвет волос (BLK, BRO, BLN)") end; imgui.NextColumn()
            imgui.InputText('##eyes'..i, person.eyes, ffi.sizeof(person.eyes)); if imgui.IsItemHovered() then imgui.SetTooltip("Цвет глаз (BLK, BRO, BLU, GRN)") end; imgui.NextColumn()
            imgui.InputText('##height'..i, person.height, ffi.sizeof(person.height)); if imgui.IsItemHovered() then imgui.SetTooltip("Рост в футах и дюймах (например, 602 = 6'2)") end; imgui.NextColumn()
            imgui.InputText('##weight'..i, person.weight, ffi.sizeof(person.weight)); if imgui.IsItemHovered() then imgui.SetTooltip("Вес в фунтах") end; imgui.NextColumn()
            imgui.InputText('##dob'..i, person.dob, ffi.sizeof(person.dob)); if imgui.IsItemHovered() then imgui.SetTooltip("Дата рождения (ММ/ДД/ГГГГ)") end; imgui.NextColumn()
            imgui.InputText('##age'..i, person.age, ffi.sizeof(person.age)); if imgui.IsItemHovered() then imgui.SetTooltip("Возраст (полных лет)") end; imgui.NextColumn()
            imgui.InputText('##name'..i, person.name_address, ffi.sizeof(person.name_address)); if imgui.IsItemHovered() then imgui.SetTooltip("Имя и фамилия, либо обвинение, если задержан") end; imgui.NextColumn()
            imgui.InputText('##action'..i, person.action_taken, ffi.sizeof(person.action_taken)); if imgui.IsItemHovered() then imgui.SetTooltip("Принятые меры в отношении данного лица") end; imgui.NextColumn()
        end
        imgui.Columns(1)

        imgui.Separator()
        imgui.Text('NARRATIVE / FOLLOW-UP REPORT'); if imgui.IsItemHovered() then imgui.SetTooltip("ОПИСАНИЕ / РЕПОРТ") end
        local region = imgui.GetContentRegionAvail()
        local multiline_size = imgui.new('ImVec2', region.x, region.y - 80)
        imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.95, 0.95, 0.95, 1.0))
        imgui.BeginChild("narrative_fu_edit_bg", multiline_size, true)
        imgui.InputTextMultiline('##narrative', b.narrative_text, ffi.sizeof(b.narrative_text), imgui.new('ImVec2', -1, -1))
        imgui.EndChild()
        imgui.PopStyleColor(1)

        imgui.Separator()
        imgui.Checkbox('PROPERTY BOOKED', b.property_booked); if imgui.IsItemHovered() then imgui.SetTooltip("ИМУЩЕСТВО ИЗЪЯТО") end
        imgui.SameLine()
        imgui.Checkbox('IF YES, FORM 16.08 COMPLETED?', b.form_16_08_completed); if imgui.IsItemHovered() then imgui.SetTooltip("ЕСЛИ ДА, ФОРМА 16.08 ЗАПОЛНЕНА?") end

        imgui.PushItemWidth(300); imgui.InputText('REPORTING OFFICER', b.reporting_officer, ffi.sizeof(b.reporting_officer)); if imgui.IsItemHovered() then imgui.SetTooltip("ОФИЦЕР") end; imgui.PopItemWidth(); imgui.SameLine()
        imgui.PushItemWidth(100); imgui.InputText('SERIAL NO.', b.officer_serial, ffi.sizeof(b.officer_serial)); if imgui.IsItemHovered() then imgui.SetTooltip("НОМЕР ЖЕТОНА") end; imgui.PopItemWidth(); imgui.SameLine()
        imgui.PushItemWidth(100); imgui.InputText('DIVISION/DETAIL', b.officer_division, ffi.sizeof(b.officer_division)); if imgui.IsItemHovered() then imgui.SetTooltip("ОТДЕЛ") end; imgui.PopItemWidth()

        
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.2, 0.2, 0.2, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.3, 0.3, 0.3, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.4, 0.4, 0.4, 1.0))
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.7, 0.7, 0.7, 1.0))

        if imgui.Button("Save Report", imgui.new('ImVec2', 150, 30)) then
            saveFollowUpReport()
        end
        imgui.SameLine()
        if imgui.Button("Clear Form", imgui.new('ImVec2', 120, 30)) then
            
        end
        imgui.PopStyleColor(4) 
        
        imgui.PopStyleColor(3) 
    end
    imgui.End()
    if not p_open[0] then switchRMSForm(nil) end
end

renderTCRWindow = function()
    if not tcrReportBuffers then return end
    local p_open = imgui.new.bool(true)
    imgui.SetNextWindowSize(imgui.new('ImVec2', 1100, 560), imgui.Cond.FirstUseEver)

    if imgui.Begin("Traffic Collision Report", p_open) then
        
        local draw_list = imgui.GetWindowDrawList()
        local pos = imgui.GetWindowPos()
        local size = imgui.GetWindowSize()
        draw_list:AddRectFilled(pos, imgui.new('ImVec2', pos.x + size.x, pos.y + size.y), 0xFFFFFFFF)
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.0, 0.0, 0.0, 1.0))
        imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0.9, 0.9, 0.9, 1.0))
        imgui.PushStyleColor(imgui.Col.CheckMark, imgui.ImVec4(0.4, 0.4, 0.4, 1.0))

        local b = tcrReportBuffers

        
        imgui.Text('LOS SANTOS POLICE DEPARTMENT - TRAFFIC COLLISION REPORT')

        imgui.SameLine(imgui.GetWindowWidth() - 250)
        imgui.Text("DR NO."); if imgui.IsItemHovered() then imgui.SetTooltip("Номер дела") end
        imgui.SameLine()
        imgui.PushItemWidth(150)
        local potential_dr_no = imgui.new.char[32](string.format("TCR%s-%04d", os.date("%y%m"), recordsState.next_record_id))
        imgui.InputText("##DRNO_TCR", potential_dr_no, ffi.sizeof(potential_dr_no), imgui.InputTextFlags.ReadOnly)
        if imgui.IsItemHovered() then imgui.SetTooltip("Номер будет присвоен при сохранении") end
        imgui.PopItemWidth()

        imgui.Text("Primary Information")
        imgui.Columns(3, "InfoColumns", false)
        imgui.InputText('Location of Collision', b.location, ffi.sizeof(b.location)); if imgui.IsItemHovered() then imgui.SetTooltip("Место ДТП") end
        imgui.NextColumn()
        imgui.InputText('Date', b.date, ffi.sizeof(b.date)); if imgui.IsItemHovered() then imgui.SetTooltip("Дата") end
        imgui.NextColumn()
        imgui.InputText('Time', b.time, ffi.sizeof(b.time)); if imgui.IsItemHovered() then imgui.SetTooltip("Время") end
        imgui.Columns(1)

        imgui.Columns(2, "OfficerColumns", false)
        imgui.InputText('Reporting Officer', b.reporting_officer, ffi.sizeof(b.reporting_officer)); if imgui.IsItemHovered() then imgui.SetTooltip("Офицер, составивший репорт") end
        imgui.NextColumn()
        imgui.InputText('Badge No.', b.officer_id, ffi.sizeof(b.officer_id)); if imgui.IsItemHovered() then imgui.SetTooltip("Номер жетона") end
        imgui.Columns(1)
        imgui.Separator()

        
        imgui.Columns(2, "PartyColumns", false)
        imgui.Text("Party 1 (V-1)")
        imgui.InputText('Driver Name##V1', b.v1_driver_name, ffi.sizeof(b.v1_driver_name)); if imgui.IsItemHovered() then imgui.SetTooltip("Имя водителя (ТС-1)") end
        imgui.InputText('License No.##V1', b.v1_driver_license, ffi.sizeof(b.v1_driver_license)); if imgui.IsItemHovered() then imgui.SetTooltip("Номер ВУ (ТС-1)") end
        imgui.InputText('Vehicle Year/Make##V1', b.v1_vehicle_year_make, ffi.sizeof(b.v1_vehicle_year_make)); if imgui.IsItemHovered() then imgui.SetTooltip("Год/марка автомобиля (ТС-1)") end
        imgui.InputText('Plate No.##V1', b.v1_vehicle_plate, ffi.sizeof(b.v1_vehicle_plate)); if imgui.IsItemHovered() then imgui.SetTooltip("Гос. номер (ТС-1)") end
        imgui.InputText('Insurance Co.##V1', b.v1_insurance, ffi.sizeof(b.v1_insurance)); if imgui.IsItemHovered() then imgui.SetTooltip("Страховая компания (ТС-1)") end
        imgui.NextColumn()

        
        imgui.Text("Party 2 (V-2)")
        imgui.InputText('Driver Name##V2', b.v2_driver_name, ffi.sizeof(b.v2_driver_name)); if imgui.IsItemHovered() then imgui.SetTooltip("Имя водителя (ТС-2)") end
        imgui.InputText('License No.##V2', b.v2_driver_license, ffi.sizeof(b.v2_driver_license)); if imgui.IsItemHovered() then imgui.SetTooltip("Номер ВУ (ТС-2)") end
        imgui.InputText('Vehicle Year/Make##V2', b.v2_vehicle_year_make, ffi.sizeof(b.v2_vehicle_year_make)); if imgui.IsItemHovered() then imgui.SetTooltip("Год/марка автомобиля (ТС-2)") end
        imgui.InputText('Plate No.##V2', b.v2_vehicle_plate, ffi.sizeof(b.v2_vehicle_plate)); if imgui.IsItemHovered() then imgui.SetTooltip("Гос. номер (ТС-2)") end
        imgui.InputText('Insurance Co.##V2', b.v2_insurance, ffi.sizeof(b.v2_insurance)); if imgui.IsItemHovered() then imgui.SetTooltip("Страховая компания (ТС-2)") end
        imgui.Columns(1)
        imgui.Separator()

        
        imgui.Text("Collision Details")
        imgui.Columns(3, "ConditionsColumns", false)
        imgui.Combo('Type of Collision', b.collision_type, collisionTypes_c, #collisionTypes); if imgui.IsItemHovered() then imgui.SetTooltip("Тип столкновения") end
        imgui.NextColumn()
        imgui.Combo('Weather Conditions', b.weather_condition, weatherConditions_c, #weatherConditions); if imgui.IsItemHovered() then imgui.SetTooltip("Погодные условия") end
        imgui.NextColumn()
        imgui.Combo('Road Conditions', b.road_condition, roadConditions_c, #roadConditions); if imgui.IsItemHovered() then imgui.SetTooltip("Дорожные условия") end
        imgui.Columns(1)
        imgui.Separator()

        
        imgui.Text('Narrative'); if imgui.IsItemHovered() then imgui.SetTooltip("Повествование: подробное описание обстоятельств ДТП") end
        imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.95, 0.95, 0.95, 1.0))
        imgui.BeginChild("narrative_tcr_edit_bg", imgui.new('ImVec2', -1, 100), true)
        imgui.InputTextMultiline('##narrative', b.narrative, ffi.sizeof(b.narrative), imgui.new('ImVec2', -1, 100))
        imgui.EndChild()
        imgui.PopStyleColor(1)
        imgui.Separator()

        
        imgui.Text("Conclusion & Actions Taken")
        imgui.InputText('Primary Collision Factor (PCF)', b.pcf_factor, ffi.sizeof(b.pcf_factor))

        imgui.Checkbox('Injuries Reported', b.injuries); if imgui.IsItemHovered() then imgui.SetTooltip("Имеются пострадавшие") end
        imgui.SameLine(200)
        imgui.Checkbox('Vehicle(s) Towed', b.towed); if imgui.IsItemHovered() then imgui.SetTooltip("Транспорт эвакуирован") end
        imgui.SameLine(400)
        imgui.Checkbox('Citations Issued', b.citations_issued); if imgui.IsItemHovered() then imgui.SetTooltip("Выписаны штрафы") end
        imgui.Separator()

        
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.2, 0.2, 0.2, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.3, 0.3, 0.3, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.4, 0.4, 0.4, 1.0))
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.7, 0.7, 0.7, 1.0))

        if imgui.Button("Save Report", imgui.new('ImVec2', 150, 30)) then
            saveTCR()
        end
        imgui.SameLine()
        if imgui.Button("Close", imgui.new('ImVec2', 150, 30)) then
            switchRMSForm(nil)
        end
        imgui.PopStyleColor(4) 

        imgui.PopStyleColor(3) 
    end
    imgui.End()
    if not p_open[0] then switchRMSForm(nil) end
end

renderArrestWindow = function()
    if not arrestRecordBuffers then return end
    local p_open = imgui.new.bool(true)
    imgui.SetNextWindowSize(imgui.new('ImVec2', 1300, 680), imgui.Cond.FirstUseEver)

    if imgui.Begin("Arrest Report", p_open) then
        local draw_list = imgui.GetWindowDrawList()
        local pos = imgui.GetWindowPos()
        local size = imgui.GetWindowSize()
        draw_list:AddRectFilled(pos, imgui.new('ImVec2', pos.x + size.x, pos.y + size.y), 0xFFFFFFFF)

        
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.0, 0.0, 0.0, 1.0))
        imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0.9, 0.9, 0.9, 1.0))
        imgui.PushStyleColor(imgui.Col.CheckMark, imgui.ImVec4(0.4, 0.4, 0.4, 1.0))

        local b = arrestRecordBuffers

        
        imgui.Text("LOS SANTOS POLICE DEPARTMENT - ARREST REPORT")
        imgui.SameLine(imgui.GetWindowWidth() - 300)
        imgui.Text("DR NO."); if imgui.IsItemHovered() then imgui.SetTooltip("Номер дела") end
        imgui.SameLine()
        imgui.PushItemWidth(150)
        local potential_dr_no = imgui.new.char[32](string.format("AR%s-%04d", os.date("%y%m"), recordsState.next_record_id))
        imgui.InputText("##DRNO", potential_dr_no, ffi.sizeof(potential_dr_no), imgui.InputTextFlags.ReadOnly)
        if imgui.IsItemHovered() then imgui.SetTooltip("Номер будет присвоен при сохранении") end
        imgui.PopItemWidth()
        imgui.Separator()

        
        imgui.Text("ARRESTEE INFORMATION")
        imgui.Columns(4, "SubjectInfo1")
        imgui.InputText("Last Name", b.last_name, ffi.sizeof(b.last_name)); if imgui.IsItemHovered() then imgui.SetTooltip("Фамилия") end
        imgui.NextColumn()
        imgui.InputText("First Name", b.first_name, ffi.sizeof(b.first_name)); if imgui.IsItemHovered() then imgui.SetTooltip("Имя") end
        imgui.NextColumn()
        imgui.InputText("Middle Name", b.middle_name, ffi.sizeof(b.middle_name)); if imgui.IsItemHovered() then imgui.SetTooltip("Отчество / Второе имя") end
        imgui.NextColumn()
        imgui.InputText("Moniker/Alias", b.moniker, ffi.sizeof(b.moniker)); if imgui.IsItemHovered() then imgui.SetTooltip("Прозвище / Псевдоним") end
        imgui.Columns(1)

        imgui.Columns(6, "SubjectInfo2")
        imgui.InputText("Sex", b.sex, ffi.sizeof(b.sex)); if imgui.IsItemHovered() then imgui.SetTooltip("Пол (M/F)") end
        imgui.NextColumn()
        imgui.InputText("Descent", b.descent, ffi.sizeof(b.descent)); if imgui.IsItemHovered() then imgui.SetTooltip("Раса") end
        imgui.NextColumn()
        imgui.InputText("Hair", b.hair, ffi.sizeof(b.hair)); if imgui.IsItemHovered() then imgui.SetTooltip("Цвет волос") end
        imgui.NextColumn()
        imgui.InputText("Eyes", b.eyes, ffi.sizeof(b.eyes)); if imgui.IsItemHovered() then imgui.SetTooltip("Цвет глаз") end
        imgui.NextColumn()
        imgui.InputText("Height", b.height, ffi.sizeof(b.height)); if imgui.IsItemHovered() then imgui.SetTooltip("Рост") end
        imgui.NextColumn()
        imgui.InputText("Weight", b.weight, ffi.sizeof(b.weight)); if imgui.IsItemHovered() then imgui.SetTooltip("Вес") end
        imgui.Columns(1)

        imgui.Columns(3, "SubjectInfo3")
        imgui.InputText("Date of Birth", b.dob, ffi.sizeof(b.dob)); if imgui.IsItemHovered() then imgui.SetTooltip("Дата рождения") end
        imgui.NextColumn()
        imgui.InputText("Age", b.age, ffi.sizeof(b.age)); if imgui.IsItemHovered() then imgui.SetTooltip("Возраст") end
        imgui.NextColumn()
        imgui.InputText("Booking No.", b.booking_no, ffi.sizeof(b.booking_no)); if imgui.IsItemHovered() then imgui.SetTooltip("Номер бронирования камеры в локальном месте содержания") end
        imgui.Columns(1)
        imgui.Separator()

        
        imgui.Text("ARREST DETAILS")
        imgui.Columns(3, "ArrestDetails")
        imgui.InputText("Location of Arrest", b.location_of_arrest, ffi.sizeof(b.location_of_arrest)); if imgui.IsItemHovered() then imgui.SetTooltip("Место задержания") end
        imgui.NextColumn()
        imgui.InputText("Date Arrested", b.date_arrested, ffi.sizeof(b.date_arrested)); if imgui.IsItemHovered() then imgui.SetTooltip("Дата задержания") end
        imgui.NextColumn()
        imgui.InputText("Time Arrested", b.time_arrested, ffi.sizeof(b.time_arrested)); if imgui.IsItemHovered() then imgui.SetTooltip("Время задержания") end
        imgui.Columns(1)

        imgui.Text("CHARGE:"); if imgui.IsItemHovered() then imgui.SetTooltip("Обвинение") end
        imgui.InputText("##Charge", b.charge, ffi.sizeof(b.charge))

        imgui.Columns(3, "ArrestDetails2")
        imgui.InputText("Location Crime Committed", b.crime_location, ffi.sizeof(b.crime_location)); if imgui.IsItemHovered() then imgui.SetTooltip("Место совершения преступления") end
        imgui.NextColumn()
        imgui.InputText("Arresting Officer", b.arresting_officer, ffi.sizeof(b.arresting_officer)); if imgui.IsItemHovered() then imgui.SetTooltip("Задерживающий офицер") end
        imgui.NextColumn()
        imgui.InputText("Serial No.", b.officer_serial, ffi.sizeof(b.officer_serial)); if imgui.IsItemHovered() then imgui.SetTooltip("Номер жетона") end
        imgui.Columns(1)
        imgui.Separator()

        
        imgui.Text("OTHER INVOLVED PERSONS")
        imgui.Columns(2)
        imgui.InputText("Name (Last, First)", b.involved_person_name, ffi.sizeof(b.involved_person_name)); if imgui.IsItemHovered() then imgui.SetTooltip("Имя другого вовлеченного лица") end
        imgui.NextColumn()
        imgui.InputText("Details (Sex/Race/DOB)", b.involved_person_details, ffi.sizeof(b.involved_person_details)); if imgui.IsItemHovered() then imgui.SetTooltip("Детали (Пол/Раса/Дата рождения)") end
        imgui.Columns(1)
        imgui.Separator()

        
        imgui.Text("NARRATIVE (SOURCE OF ACTIVITY / INVESTIGATION)"); if imgui.IsItemHovered() then imgui.SetTooltip("Повествование (Источник активности / Расследование)") end
        
        local region = imgui.GetContentRegionAvail()
        imgui.InputTextMultiline("##narrative", b.narrative, ffi.sizeof(b.narrative), imgui.new('ImVec2', region.x, 150))
        imgui.Separator()

        
        imgui.Text("PROPERTY TAKEN INTO CUSTODY"); if imgui.IsItemHovered() then imgui.SetTooltip("Имущество, взятое под стражу") end
        imgui.Columns(5, "PropertyHeader")
        imgui.Text("Quant."); if imgui.IsItemHovered() then imgui.SetTooltip("Кол-во") end; imgui.NextColumn()
        imgui.Text("Article"); if imgui.IsItemHovered() then imgui.SetTooltip("Предмет") end; imgui.NextColumn()
        imgui.Text("Brand"); if imgui.IsItemHovered() then imgui.SetTooltip("Бренд") end; imgui.NextColumn()
        imgui.Text("Model"); if imgui.IsItemHovered() then imgui.SetTooltip("Модель") end; imgui.NextColumn()
        imgui.Text("Misc./Color/Caliber"); if imgui.IsItemHovered() then imgui.SetTooltip("Разное/Цвет/Калибр") end; imgui.NextColumn()
        imgui.Separator()

        for i, item in ipairs(b.property_items) do
            imgui.PushItemWidth(-1)
            imgui.InputText("##quant"..i, item.quant, ffi.sizeof(item.quant)); imgui.NextColumn()
            imgui.InputText("##article"..i, item.article, ffi.sizeof(item.article)); imgui.NextColumn()
            imgui.InputText("##brand"..i, item.brand, ffi.sizeof(item.brand)); imgui.NextColumn()
            imgui.InputText("##model"..i, item.model, ffi.sizeof(item.model)); imgui.NextColumn()
            imgui.InputText("##desc"..i, item.desc, ffi.sizeof(item.desc)); imgui.NextColumn()
            imgui.PopItemWidth()
        end
        imgui.Columns(1)
        imgui.Separator()

        
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.2, 0.2, 0.2, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.3, 0.3, 0.3, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.4, 0.4, 0.4, 1.0))
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.7, 0.7, 0.7, 1.0))

        if imgui.Button("Save Report", imgui.new('ImVec2', 150, 30)) then
            saveArrestRecord()
        end
        imgui.SameLine()
        if imgui.Button("Close", imgui.new('ImVec2', 150, 30)) then
            switchRMSForm(nil)
        end
        imgui.PopStyleColor(4)
        
        imgui.PopStyleColor(3)
    end
    imgui.End()
    if not p_open[0] then switchRMSForm(nil) end
end

renderIncidentWindow = function()
    if not incidentReportBuffers then return end
    local p_open = imgui.new.bool(true)
    imgui.SetNextWindowSize(imgui.new('ImVec2', 1300, 750), imgui.Cond.FirstUseEver)

    if imgui.Begin("Incident Report", p_open) then
        local draw_list = imgui.GetWindowDrawList()
        local pos = imgui.GetWindowPos()
        local size = imgui.GetWindowSize()
        draw_list:AddRectFilled(pos, imgui.new('ImVec2', pos.x + size.x, pos.y + size.y), 0xFFFFFFFF)

        
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.0, 0.0, 0.0, 1.0))
        imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0.9, 0.9, 0.9, 1.0))
        imgui.PushStyleColor(imgui.Col.CheckMark, imgui.ImVec4(0.4, 0.4, 0.4, 1.0))

        local b = incidentReportBuffers

        
        imgui.Text("LOS SANTOS POLICE DEPARTMENT - INCIDENT REPORT (DR)")
        imgui.SameLine(imgui.GetWindowWidth() - 300)
        imgui.Text("DR NO."); if imgui.IsItemHovered() then imgui.SetTooltip("Номер дела") end
        imgui.SameLine()
        imgui.PushItemWidth(150)
        local potential_dr_no = imgui.new.char[32](string.format("IN%s-%04d", os.date("%y%m"), recordsState.next_record_id))
        imgui.InputText("##DRNO", potential_dr_no, ffi.sizeof(potential_dr_no), imgui.InputTextFlags.ReadOnly)
        if imgui.IsItemHovered() then imgui.SetTooltip("Номер будет присвоен при сохранении") end
        imgui.PopItemWidth()
        imgui.Separator()

        
        imgui.Text("INCIDENT INFORMATION")
        imgui.Columns(4)
        imgui.InputText("Date of Report", b.report_date, ffi.sizeof(b.report_date)); if imgui.IsItemHovered() then imgui.SetTooltip("Дата репорта") end; imgui.NextColumn()
        imgui.InputText("Time", b.report_time, ffi.sizeof(b.report_time)); if imgui.IsItemHovered() then imgui.SetTooltip("Время репорта") end; imgui.NextColumn()
        imgui.InputText("Incident Date", b.incident_date, ffi.sizeof(b.incident_date)); if imgui.IsItemHovered() then imgui.SetTooltip("Дата инцидента") end; imgui.NextColumn()
        imgui.InputText("Incident Time", b.incident_time, ffi.sizeof(b.incident_time)); if imgui.IsItemHovered() then imgui.SetTooltip("Время инцидента") end; imgui.NextColumn()
        imgui.Columns(1)

        imgui.InputText("Location of Occurrence", b.location, ffi.sizeof(b.location)); if imgui.IsItemHovered() then imgui.SetTooltip("Место происшествия") end
        imgui.InputText("Incident Type (UCR Code & Description)", b.incident_type, ffi.sizeof(b.incident_type)); if imgui.IsItemHovered() then imgui.SetTooltip("Тип инцидента (код и описание)") end
        imgui.Separator()

        
        imgui.Text("INVOLVED PERSONS (V = Victim, S = Suspect, W = Witness)"); if imgui.IsItemHovered() then imgui.SetTooltip("Вовлеченные лица (V=Жертва, S=Подозреваемый, W=Свидетель)") end
        imgui.Columns(6, "PersonsHeader")
        imgui.Text("Type"); imgui.NextColumn()
        imgui.Text("Name (Last, First)"); imgui.NextColumn()
        imgui.Text("D.O.B."); imgui.NextColumn()
        imgui.Text("Sex"); imgui.NextColumn()
        imgui.Text("Desc"); imgui.NextColumn()
        imgui.Text("Phone"); imgui.NextColumn()
        imgui.Separator()
        for i, person in ipairs(b.persons) do
            imgui.PushItemWidth(-1)
            imgui.InputText("##v_ptype"..i, person.type, ffi.sizeof(person.type)); if imgui.IsItemHovered() then imgui.SetTooltip("Тип (V/W)") end; imgui.NextColumn()
            imgui.InputText("##v_pname"..i, person.name, ffi.sizeof(person.name)); if imgui.IsItemHovered() then imgui.SetTooltip("Имя (Фамилия, Имя)") end; imgui.NextColumn()
            imgui.InputText("##v_pdob"..i, person.dob, ffi.sizeof(person.dob)); if imgui.IsItemHovered() then imgui.SetTooltip("Дата рождения") end; imgui.NextColumn()
            imgui.InputText("##v_psex"..i, person.sex, ffi.sizeof(person.sex)); if imgui.IsItemHovered() then imgui.SetTooltip("Пол") end; imgui.NextColumn()
            imgui.InputText("##v_pdesc"..i, person.desc, ffi.sizeof(person.desc)); if imgui.IsItemHovered() then imgui.SetTooltip("Раса") end; imgui.NextColumn()
            imgui.InputText("##v_pphone"..i, person.phone, ffi.sizeof(person.phone)); if imgui.IsItemHovered() then imgui.SetTooltip("Телефон") end; imgui.NextColumn()
            imgui.PopItemWidth()
        end
        imgui.Columns(1)
        imgui.Separator()

        
        imgui.Text("PROPERTY (Stolen, Damaged, Evidence, etc.)"); if imgui.IsItemHovered() then imgui.SetTooltip("Имущество (украдено, повреждено, улики и т.д.)") end
        imgui.Columns(4, "PropertyHeader")
        imgui.Text("Code"); imgui.NextColumn()
        imgui.Text("Article"); imgui.NextColumn()
        imgui.Text("Description / Serial No."); imgui.NextColumn()
        imgui.Text("Value ($)"); imgui.NextColumn()
        imgui.Separator()
        for i, prop in ipairs(b.property) do
            imgui.PushItemWidth(-1)
            imgui.InputText("##pcode"..i, prop.code, ffi.sizeof(prop.code)); imgui.NextColumn()
            imgui.InputText("##particle"..i, prop.article, ffi.sizeof(prop.article)); imgui.NextColumn()
            imgui.InputText("##pdesc"..i, prop.description, ffi.sizeof(prop.description)); imgui.NextColumn()
            imgui.InputText("##pvalue"..i, prop.value, ffi.sizeof(prop.value)); imgui.NextColumn()
            imgui.PopItemWidth()
        end
        imgui.Columns(1)
        imgui.Separator()

        
        imgui.Text("MODUS OPERANDI (How was the crime committed?)"); if imgui.IsItemHovered() then imgui.SetTooltip("Способ совершения преступления") end
        local region_mo = imgui.GetContentRegionAvail()
        imgui.InputTextMultiline("##mo", b.modus_operandi, ffi.sizeof(b.modus_operandi), imgui.new('ImVec2', region_mo.x, 40))
        imgui.Separator()
        imgui.Text("NARRATIVE (Chronological account of events andactions taken)"); if imgui.IsItemHovered() then imgui.SetTooltip("Повествование (хронологический отчет о событиях и предпринятых действиях)") end
        local region = imgui.GetContentRegionAvail()
        local narrative_height = math.max(40, region.y - 120)
        imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.95, 0.95, 0.95, 1.0))
        imgui.BeginChild("narrative_inc_edit_bg", imgui.new('ImVec2', region.x, narrative_height), true)
        imgui.InputTextMultiline("##narrative", b.narrative, ffi.sizeof(b.narrative), imgui.new('ImVec2', -1, -1))
        imgui.EndChild()
        imgui.PopStyleColor(1)
        imgui.Separator()
        
        imgui.Columns(3)
        imgui.InputText("Reporting Officer", b.reporting_officer, ffi.sizeof(b.reporting_officer)); if imgui.IsItemHovered() then imgui.SetTooltip("Офицер") end; imgui.NextColumn()
        imgui.InputText("Serial No.", b.officer_serial, ffi.sizeof(b.officer_serial)); if imgui.IsItemHovered() then imgui.SetTooltip("Номер жетона") end; imgui.NextColumn()
        imgui.Text("Case Status:"); if imgui.IsItemHovered() then imgui.SetTooltip("Статус дела") end   
        
        local case_statuses = { "Active", "Suspended", "Closed" }
        for i, status_name in ipairs(case_statuses) do
            local status_value = i - 1 

            if b.case_status == status_value then
                
                imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.2, 0.5, 0.9, 1.0))
                imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.3, 0.6, 1.0, 1.0))
                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1.0, 1.0, 1.0, 1.0))
            else
                
                imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.8, 0.8, 0.8, 1.0))
                imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.9, 0.9, 0.9, 1.0))
                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.0, 0.0, 0.0, 1.0))
            end

            imgui.SameLine()
            if imgui.Button(status_name, imgui.new('ImVec2', 80, 0)) then
                b.case_status = status_value
            end
            
            imgui.PopStyleColor(3) 
        end
        imgui.NextColumn()
        imgui.Columns(1)

        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.2, 0.2, 0.2, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.3, 0.3, 0.3, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.4, 0.4, 0.4, 1.0))
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.7, 0.7, 0.7, 1.0))
        
        if imgui.Button("Save Report", imgui.new('ImVec2', 150, 30)) then
            saveIncidentReport()
        end
        imgui.SameLine()
        if imgui.Button("Close", imgui.new('ImVec2', 150, 30)) then
            switchRMSForm(nil)
        end
        imgui.PopStyleColor(4)
        imgui.PopStyleColor(3)
    end
    imgui.End()
    if not p_open[0] then switchRMSForm(nil) end
end

renderComplaintWindow = function()
    if not complaintReportBuffers then return end
    local p_open = imgui.new.bool(true)
    imgui.SetNextWindowSize(imgui.new('ImVec2', 1200, 580), imgui.Cond.FirstUseEver)

    if imgui.Begin("Complaint Report", p_open) then
        local draw_list = imgui.GetWindowDrawList()
        local pos = imgui.GetWindowPos()
        local size = imgui.GetWindowSize()
        draw_list:AddRectFilled(pos, imgui.new('ImVec2', pos.x + size.x, pos.y + size.y), 0xFFFFFFFF)
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.0, 0.0, 0.0, 1.0))
        imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0.9, 0.9, 0.9, 1.0))
        imgui.PushStyleColor(imgui.Col.CheckMark, imgui.ImVec4(0.4, 0.4, 0.4, 1.0))

        local b = complaintReportBuffers

        
        imgui.Text("LSPD COMPLAINT REPORT"); if imgui.IsItemHovered() then imgui.SetTooltip("ЗАЯВЛЕНИЕ О ПРОИСШЕСТВИИ") end
        local potential_dr_no = ffi.string(b.dr_no) == "" and string.format("COMP%s-%04d", os.date("%y%m"), recordsState.next_record_id) or ffi.string(b.dr_no)
        local dr_no_buffer = imgui.new.char[32](potential_dr_no)
        imgui.SameLine(imgui.GetWindowWidth() - 250)
        imgui.Text("DR NO."); if imgui.IsItemHovered() then imgui.SetTooltip("Номер дела") end
        imgui.SameLine()
        imgui.PushItemWidth(150)
        imgui.InputText("##DRNO_COMP", dr_no_buffer, ffi.sizeof(dr_no_buffer), imgui.InputTextFlags.ReadOnly)
        if imgui.IsItemHovered() then imgui.SetTooltip("Формат: COMP<Год><Месяц>-<ID>\nГенерируется автоматически при сохранении.") end
        imgui.PopItemWidth()
        imgui.Separator()

        imgui.Text("Complainant Information"); if imgui.IsItemHovered() then imgui.SetTooltip("Информация о заявителе") end
        imgui.Columns(2, " complainant_info")
        imgui.InputText("Name (Last, First)", b.c_name, ffi.sizeof(b.c_name)); if imgui.IsItemHovered() then imgui.SetTooltip("Имя заявителя (Фамилия, Имя)") end
        imgui.InputText("Address", b.c_address, ffi.sizeof(b.c_address)); if imgui.IsItemHovered() then imgui.SetTooltip("Адрес проживания заявителя") end
        imgui.NextColumn()
        imgui.InputText("Phone Number", b.c_phone, ffi.sizeof(b.c_phone)); if imgui.IsItemHovered() then imgui.SetTooltip("Контактный телефон") end
        imgui.InputText("Date of Birth", b.c_dob, ffi.sizeof(b.c_dob)); if imgui.IsItemHovered() then imgui.SetTooltip("Дата рождения") end
        imgui.Columns(1)
        imgui.Separator()
        imgui.Text("Incident Details"); if imgui.IsItemHovered() then imgui.SetTooltip("Детали происшествия") end
        imgui.InputText("Type of Incident", b.incident_type, ffi.sizeof(b.incident_type)); if imgui.IsItemHovered() then imgui.SetTooltip("Тип происшествия (например: кража, нападение, вандализм)") end
        imgui.Columns(2, "incident_details")
        imgui.InputText("Date Occurred", b.incident_date_occurred, ffi.sizeof(b.incident_date_occurred)); if imgui.IsItemHovered() then imgui.SetTooltip("Дата, когда произошло событие") end
        imgui.NextColumn()
        imgui.InputText("Time Occurred", b.incident_time_occurred, ffi.sizeof(b.incident_time_occurred)); if imgui.IsItemHovered() then imgui.SetTooltip("Время, когда произошло событие (приблизительное)") end
        imgui.Columns(1)
        imgui.InputText("Location of Incident", b.incident_location, ffi.sizeof(b.incident_location)); if imgui.IsItemHovered() then imgui.SetTooltip("Адрес, где произошло событие") end

        
        imgui.Separator()
        imgui.Text("Narrative / Statement of Complainant"); if imgui.IsItemHovered() then imgui.SetTooltip("Повествование / Показания заявителя") end
        imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.95, 0.95, 0.95, 1.0))
        imgui.BeginChild("narrative_comp_edit_bg", imgui.new('ImVec2', -1, 150), true)
        imgui.InputTextMultiline('##narrative', b.narrative, ffi.sizeof(b.narrative)); if imgui.IsItemHovered() then imgui.SetTooltip("Опишите подробно, что произошло, в хронологическом порядке. Включите описание подозреваемых, свидетелей, украденного имущества и т.д.") end
        imgui.EndChild()
        imgui.PopStyleColor(1)        
        imgui.Separator()
        imgui.Columns(2, "involved_things")
        imgui.Text("Persons Involved (Victims, Suspects, Witnesses)"); if imgui.IsItemHovered() then imgui.SetTooltip("Вовлеченные лица (жертвы, подозреваемые, свидетели)") end
        local region1 = imgui.GetContentRegionAvail()
        imgui.InputTextMultiline('##persons', b.involved_persons, ffi.sizeof(b.involved_persons), imgui.new('ImVec2', region1.x, 80))
        imgui.NextColumn()
        imgui.Text("Property Involved (Stolen, Damaged, Evidence)"); if imgui.IsItemHovered() then imgui.SetTooltip("Вовлеченное имущество (украдено, повреждено, улики)") end
        local region2 = imgui.GetContentRegionAvail()
        imgui.InputTextMultiline('##property', b.involved_property, ffi.sizeof(b.involved_property), imgui.new('ImVec2', region2.x, 80))
        imgui.Columns(1)

        imgui.Separator()
        imgui.Columns(2, "officer_info")
        imgui.InputText("Reporting Officer", b.reporting_officer, ffi.sizeof(b.reporting_officer)); if imgui.IsItemHovered() then imgui.SetTooltip("Офицер, принявший заявление") end
        imgui.NextColumn()
        imgui.InputText("Serial No.", b.officer_serial, ffi.sizeof(b.officer_serial)); if imgui.IsItemHovered() then imgui.SetTooltip("Номер жетона") end
        imgui.Columns(1)
        imgui.Separator()

        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.2, 0.2, 0.2, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.3, 0.3, 0.3, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.4, 0.4, 0.4, 1.0))
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.7, 0.7, 0.7, 1.0))
        
        if imgui.Button("Save Complaint", imgui.new('ImVec2', 150, 30)) then
            saveComplaint()
        end
        imgui.SameLine()
        if imgui.Button("Close", imgui.new('ImVec2', 150, 30)) then
            switchRMSForm(nil)
        end
        imgui.PopStyleColor(4)

        imgui.PopStyleColor(3)
    end
    imgui.End()
    if not p_open[0] then switchRMSForm(nil) end
end

renderCCWSuspensionWindow = function()
    if not ccwSuspensionBuffers then return end
    local p_open = imgui.new.bool(true)
    imgui.SetNextWindowSize(imgui.new('ImVec2', 900, 535), imgui.Cond.FirstUseEver)

    if imgui.Begin("CCW License Suspension/Revocation", p_open) then
        local draw_list = imgui.GetWindowDrawList()
        local pos = imgui.GetWindowPos()
        local size = imgui.GetWindowSize()
        draw_list:AddRectFilled(pos, imgui.new('ImVec2', pos.x + size.x, pos.y + size.y), 0xFFFFFFFF)
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.0, 0.0, 0.0, 1.0))
        imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0.9, 0.9, 0.9, 1.0))
        imgui.PushStyleColor(imgui.Col.CheckMark, imgui.ImVec4(0.4, 0.4, 0.4, 1.0))

        local b = ccwSuspensionBuffers
        local suspensionReasons = { "Arrest for Felony/Violent Misdemeanor", "Domestic Violence Incident", "Mental Health Hold (5150)", "Judicial Order/Restraining Order", "Public Safety Concern", "Other" }
        local suspensionReasons_c = to_c_array(suspensionReasons)

        
        imgui.Text("LSPD - NOTICE OF CCW SUSPENSION / REVOCATION")
        
        local potential_dr_no = imgui.new.char[32](string.format("CCW%s-%04d", os.date("%y%m"), recordsState.next_record_id))
        imgui.SameLine(imgui.GetWindowWidth() - 250)
        imgui.Text("DR NO."); if imgui.IsItemHovered() then imgui.SetTooltip("Номер дела о приостановке") end
        imgui.SameLine()
        imgui.PushItemWidth(150)
        imgui.InputText("##DRNO_CCW", potential_dr_no, ffi.sizeof(potential_dr_no), imgui.InputTextFlags.ReadOnly)
        if imgui.IsItemHovered() then imgui.SetTooltip("Формат: CCW<Год><Месяц>-<ID>\nГенерируется автоматически при сохранении.") end
        imgui.PopItemWidth()
        imgui.Separator()

        
        imgui.Text("License Holder Information"); if imgui.IsItemHovered() then imgui.SetTooltip("Информация о владельце лицензии") end
        imgui.Columns(2, "lh_info")
        imgui.InputText("Name (Last, First)", b.lh_name, ffi.sizeof(b.lh_name)); if imgui.IsItemHovered() then imgui.SetTooltip("Имя владельца (Фамилия, Имя)") end
        imgui.InputText("Address", b.lh_address, ffi.sizeof(b.lh_address)); if imgui.IsItemHovered() then imgui.SetTooltip("Адрес проживания") end
        imgui.NextColumn()
        imgui.InputText("Date of Birth", b.lh_dob, ffi.sizeof(b.lh_dob)); if imgui.IsItemHovered() then imgui.SetTooltip("Дата рождения") end
        imgui.InputText("CCW License Number", b.lh_license_number, ffi.sizeof(b.lh_license_number)); if imgui.IsItemHovered() then imgui.SetTooltip("Номер лицензии на скрытое ношение") end
        imgui.Columns(1)
        imgui.Separator()

        
        imgui.Text("Reason for Suspension / Revocation"); if imgui.IsItemHovered() then imgui.SetTooltip("Причина приостановки / аннулирования") end
        imgui.PushItemWidth(-1)
        imgui.Combo("##suspensionreason", b.suspension_reason, suspensionReasons_c, #suspensionReasons)
        imgui.PopItemWidth()

        imgui.Columns(2, "seizure_details")
        imgui.InputText("Date of Seizure", b.seizure_date, ffi.sizeof(b.seizure_date)); if imgui.IsItemHovered() then imgui.SetTooltip("Дата изъятия лицензии/оружия") end
        imgui.NextColumn()
        imgui.InputText("Time of Seizure", b.seizure_time, ffi.sizeof(b.seizure_time)); if imgui.IsItemHovered() then imgui.SetTooltip("Время изъятия") end
        imgui.Columns(1)
        
        imgui.Text("Firearms Seized (Make, Model, Serial No.)"); if imgui.IsItemHovered() then imgui.SetTooltip("Изъятое оружие (Марка, модель, серийный номер)") end
        local region_firearms = imgui.GetContentRegionAvail()
        imgui.InputTextMultiline('##seizedfirearms', b.seized_firearms, ffi.sizeof(b.seized_firearms), imgui.new('ImVec2', region_firearms.x, 60))
        imgui.Separator()
        
        
		imgui.Text("Related Incident Information"); if imgui.IsItemHovered() then imgui.SetTooltip("Информация о связанном инциденте") end
        if imgui.InputText("Related DR No.", b.related_dr_no, ffi.sizeof(b.related_dr_no)) then 
            ffi.copy(activeDR.number, b.related_dr_no, 32)
        end
        imgui.Text("Incident Summary"); if imgui.IsItemHovered() then imgui.SetTooltip("Краткое описание инцидента, приведшего к приостановке") end
        imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.95, 0.95, 0.95, 1.0))
        imgui.BeginChild("summary_ccw_edit_bg", imgui.new('ImVec2', -1, 80), true)
        imgui.InputTextMultiline('##incidentsummary_ccw', b.incident_summary, ffi.sizeof(b.incident_summary), imgui.new('ImVec2', -1, -1))
        imgui.EndChild()
        imgui.PopStyleColor(1)
        if imgui.IsItemHovered() then imgui.SetTooltip("Номер дела, связанного с инцидентом") end

        imgui.Columns(2, "officer_final")
        imgui.InputText("Reporting Officer", b.reporting_officer, ffi.sizeof(b.reporting_officer)); if imgui.IsItemHovered() then imgui.SetTooltip("Офицер, составивший репорт") end
        imgui.NextColumn()
        imgui.InputText("Serial No.", b.officer_serial, ffi.sizeof(b.officer_serial)); if imgui.IsItemHovered() then imgui.SetTooltip("Номер жетона") end
        imgui.Columns(1)
        imgui.Checkbox("Supervisor Notified and Concurs", b.supervisor_signature); if imgui.IsItemHovered() then imgui.SetTooltip("Супервайзер уведомлен и согласен") end
        imgui.Separator()

        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.2, 0.2, 0.2, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.3, 0.3, 0.3, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.4, 0.4, 0.4, 1.0))
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.7, 0.7, 0.7, 1.0))
        
        if imgui.Button("Submit Suspension", imgui.new('ImVec2', 180, 30)) then
            saveCCWSuspension()
        end
        imgui.SameLine()
        if imgui.Button("Close", imgui.new('ImVec2', 150, 30)) then
            switchRMSForm(nil)
        end
        imgui.PopStyleColor(4)

        imgui.PopStyleColor(3)
    end
    imgui.End()
    if not p_open[0] then switchRMSForm(nil) end
end

renderPropertyReportWindow = function()
    if not propertyReportBuffers then return end
    local p_open = imgui.new.bool(true)
    imgui.SetNextWindowSize(imgui.new('ImVec2', 900, 590), imgui.Cond.FirstUseEver)

    if imgui.Begin("Property Report (Form 16.08)", p_open) then
        local draw_list = imgui.GetWindowDrawList()
        local pos = imgui.GetWindowPos()
        local size = imgui.GetWindowSize()
        draw_list:AddRectFilled(pos, imgui.new('ImVec2', pos.x + size.x, pos.y + size.y), 0xFFFFFFFF)
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.0, 0.0, 0.0, 1.0))
        imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0.9, 0.9, 0.9, 1.0))

        local b = propertyReportBuffers

        
        imgui.Text("LOS SANTOS POLICE DEPARTMENT - PROPERTY REPORT")
        local potential_dr_no = imgui.new.char[32](string.format("PROP%s-%04d", os.date("%y%m"), recordsState.next_record_id))
        imgui.SameLine(imgui.GetWindowWidth() - 250)
        imgui.Text("DR NO."); imgui.SameLine()
        imgui.PushItemWidth(150)
        imgui.InputText("##DRNO_PROP", potential_dr_no, ffi.sizeof(potential_dr_no), imgui.InputTextFlags.ReadOnly)
        imgui.PopItemWidth()
        imgui.Separator()

        
        imgui.Text("Owner Information"); if imgui.IsItemHovered() then imgui.SetTooltip("Информация о владельце имущества") end
        imgui.InputText("Name (Last, First)", b.owner_name, ffi.sizeof(b.owner_name))
        imgui.InputText("Address", b.owner_address, ffi.sizeof(b.owner_address))
        imgui.InputText("Phone Number", b.owner_phone, ffi.sizeof(b.owner_phone))
        imgui.Separator()
        
        
        imgui.Text("Reason for Booking"); if imgui.IsItemHovered() then imgui.SetTooltip("Причина изъятия/принятия на хранение") end
        
        local booking_reasons = { "Evidence", "Found Property", "Safekeeping" }
        for i, reason_name in ipairs(booking_reasons) do
            local reason_value = i - 1 

            if b.booking_reason[0] == reason_value then
                
                imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.2, 0.5, 0.9, 1.0))
                imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.3, 0.6, 1.0, 1.0))
                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1.0, 1.0, 1.0, 1.0))
            else
                
                imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.8, 0.8, 0.8, 1.0))
                imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.9, 0.9, 0.9, 1.0))
                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.0, 0.0, 0.0, 1.0))
            end

            imgui.SameLine()
            if imgui.Button(reason_name, imgui.new('ImVec2', 120, 0)) then
                b.booking_reason[0] = reason_value
            end
            
            imgui.PopStyleColor(3) 
        end
        imgui.Separator()

        
        imgui.Text("Booked Property List")
        imgui.Columns(3, "PropertyItems", true)
        imgui.SetColumnWidth(0, 60)
        imgui.SetColumnWidth(1, imgui.GetWindowWidth() - 200)
        imgui.SetColumnWidth(2, 120)
        imgui.Text("Quant."); imgui.NextColumn()
        imgui.Text("Description (Make, Model, Serial No., Color, etc.)"); imgui.NextColumn()
        imgui.Text("Value ($)"); imgui.NextColumn()
        imgui.Separator()

        for i, item in ipairs(b.items) do
            imgui.PushItemWidth(-1)
            imgui.InputText("##quant"..i, item.quant, ffi.sizeof(item.quant)); imgui.NextColumn()
            imgui.InputText("##desc"..i, item.description, ffi.sizeof(item.description)); imgui.NextColumn()
            imgui.InputText("##value"..i, item.value, ffi.sizeof(item.value)); imgui.NextColumn()
            imgui.PopItemWidth()
        end
        imgui.Columns(1)
        imgui.Separator()

        
        imgui.Text("Narrative (Circumstances of booking)"); if imgui.IsItemHovered() then imgui.SetTooltip("Повествование (обстоятельства изъятия имущества)") end
        imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.95, 0.95, 0.95, 1.0))
        imgui.BeginChild("narrative_prop_edit_bg", imgui.new('ImVec2', -1, 80), true)
        imgui.InputTextMultiline('##narrative_prop', b.narrative, ffi.sizeof(b.narrative), imgui.new('ImVec2', -1, -1))
        imgui.EndChild()
        imgui.PopStyleColor(1)
        imgui.Separator()

        
        imgui.Columns(2, "officer_info_prop")
        imgui.InputText("Reporting Officer", b.reporting_officer, ffi.sizeof(b.reporting_officer))
        imgui.NextColumn()
        imgui.InputText("Serial No.", b.officer_serial, ffi.sizeof(b.officer_serial))
        imgui.Columns(1)
        imgui.Separator()

        
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.2, 0.2, 0.2, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.3, 0.3, 0.3, 1.0))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.4, 0.4, 0.4, 1.0))
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.7, 0.7, 0.7, 1.0))
        
        if imgui.Button("Save Report", imgui.new('ImVec2', 150, 30)) then
            savePropertyReport()
        end
        imgui.SameLine()
        if imgui.Button("Close", imgui.new('ImVec2', 150, 30)) then
            switchRMSForm(nil)
        end
        imgui.PopStyleColor(4)

        imgui.PopStyleColor(2)
    end
    imgui.End()
    if not p_open[0] then switchRMSForm(nil) end
end

local function renderArrestRecordViewer(record)
    local b = record.data
    if not b then return end 
    local unique_id = tostring(record.id) 


    imgui.BeginChild("ArrestViewer" .. unique_id, imgui.new('ImVec2', 0, 0), false, imgui.WindowFlags.NoBackground)

    local flags = imgui.InputTextFlags.ReadOnly
    local gray_bg = imgui.ImVec4(0.95, 0.95, 0.95, 1.0)
    imgui.PushStyleColor(imgui.Col.FrameBg, gray_bg)
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.0, 0.0, 0.0, 1.0))

    local function create_viewer_buffer(text, size)
        size = size or 128
        local buf = imgui.new.char[size](text or '')
        return buf, ffi.sizeof(buf)
    end
    
    
    imgui.Text("ARRESTEE INFORMATION")
    imgui.Columns(4, "SubjectInfo1Viewer")
    local lname_buf, lname_size = create_viewer_buffer(b.last_name)
    imgui.Text("Last Name"); imgui.InputText("##v_lname" .. unique_id, lname_buf, lname_size, flags)
    imgui.NextColumn()
    local fname_buf, fname_size = create_viewer_buffer(b.first_name)
    imgui.Text("First Name"); imgui.InputText("##v_fname" .. unique_id, fname_buf, fname_size, flags)
    imgui.NextColumn()
    local mname_buf, mname_size = create_viewer_buffer(b.middle_name)
    imgui.Text("Middle Name"); imgui.InputText("##v_mname" .. unique_id, mname_buf, mname_size, flags)
    imgui.NextColumn()
    local moniker_buf, moniker_size = create_viewer_buffer(b.moniker)
    imgui.Text("Moniker/Alias"); imgui.InputText("##v_moniker" .. unique_id, moniker_buf, moniker_size, flags)
    imgui.Columns(1)

    imgui.Columns(6, "SubjectInfo2Viewer")
    local sex_buf, sex_size = create_viewer_buffer(b.sex, 16)
    imgui.Text("Sex"); imgui.InputText("##v_sex" .. unique_id, sex_buf, sex_size, flags)
    imgui.NextColumn()
    local descent_buf, descent_size = create_viewer_buffer(b.descent, 16)
    imgui.Text("Descent"); imgui.InputText("##v_descent" .. unique_id, descent_buf, descent_size, flags)
    imgui.NextColumn()
    local hair_buf, hair_size = create_viewer_buffer(b.hair, 16)
    imgui.Text("Hair"); imgui.InputText("##v_hair" .. unique_id, hair_buf, hair_size, flags)
    imgui.NextColumn()
    local eyes_buf, eyes_size = create_viewer_buffer(b.eyes, 16)
    imgui.Text("Eyes"); imgui.InputText("##v_eyes" .. unique_id, eyes_buf, eyes_size, flags)
    imgui.NextColumn()
    local height_buf, height_size = create_viewer_buffer(b.height, 16)
    imgui.Text("Height"); imgui.InputText("##v_height" .. unique_id, height_buf, height_size, flags)
    imgui.NextColumn()
    local weight_buf, weight_size = create_viewer_buffer(b.weight, 16)
    imgui.Text("Weight"); imgui.InputText("##v_weight" .. unique_id, weight_buf, weight_size, flags)
    imgui.Columns(1)
    
    imgui.Columns(3, "SubjectInfo3Viewer")
    local dob_buf, dob_size = create_viewer_buffer(b.dob, 32)
    imgui.Text("Date of Birth"); imgui.InputText("##v_dob" .. unique_id, dob_buf, dob_size, flags)
    imgui.NextColumn()
    local age_buf, age_size = create_viewer_buffer(b.age, 16)
    imgui.Text("Age"); imgui.InputText("##v_age" .. unique_id, age_buf, age_size, flags)
    imgui.NextColumn()
    local booking_buf, booking_size = create_viewer_buffer(b.booking_no, 32)
    imgui.Text("Booking No."); imgui.InputText("##v_booking" .. unique_id, booking_buf, booking_size, flags)
    imgui.Columns(1)
    imgui.Separator()

    
    imgui.Text("ARREST DETAILS")
    local loc_arrest_buf, loc_arrest_size = create_viewer_buffer(b.location_of_arrest, 256)
    imgui.Text("Location of Arrest"); imgui.InputText("##v_loc_arrest" .. unique_id, loc_arrest_buf, loc_arrest_size, flags)
    imgui.Columns(2, "ArrestDetailsViewer")
    local date_arr_buf, date_arr_size = create_viewer_buffer(b.date_arrested, 32)
    imgui.Text("Date Arrested"); imgui.InputText("##v_date_arr" .. unique_id, date_arr_buf, date_arr_size, flags)
    imgui.NextColumn()
    local time_arr_buf, time_arr_size = create_viewer_buffer(b.time_arrested, 32)
    imgui.Text("Time Arrested"); imgui.InputText("##v_time_arr" .. unique_id, time_arr_buf, time_arr_size, flags)
    imgui.Columns(1)

    local charge_buf, charge_size = create_viewer_buffer(b.charge, 256)
    imgui.Text("CHARGE:")
    imgui.InputTextMultiline("##v_charge" .. unique_id, charge_buf, charge_size, imgui.new('ImVec2', -1, 40), flags)
    imgui.Separator()

    
    imgui.Text("NARRATIVE (SOURCE OF ACTIVITY / INVESTIGATION)")
    imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0.95, 0.95, 0.95, 1.0))
    imgui.BeginChild("narrative_arrest_bg", imgui.new('ImVec2', -1, 150), true)
    imgui.TextWrapped(b.narrative or "")
    imgui.EndChild()
    imgui.PopStyleColor(1)
    imgui.Separator()

    
    imgui.Text("PROPERTY TAKEN INTO CUSTODY")
    imgui.Columns(5, "PropertyHeaderViewer")
    imgui.Text("Quant."); imgui.NextColumn()
    imgui.Text("Article"); imgui.NextColumn()
    imgui.Text("Brand"); imgui.NextColumn()
    imgui.Text("Model"); imgui.NextColumn()
    imgui.Text("Misc./Color/Caliber"); imgui.NextColumn()
    imgui.Separator()

    for i, item in ipairs(b.property_items) do
        local q_buf, q_size = create_viewer_buffer(item.quant, 16)
        local a_buf, a_size = create_viewer_buffer(item.article)
        local b_buf, b_size = create_viewer_buffer(item.brand)
        local m_buf, m_size = create_viewer_buffer(item.model)
        local d_buf, d_size = create_viewer_buffer(item.desc)
        imgui.PushItemWidth(-1)
        imgui.InputText("##v_quant" .. i .. unique_id, q_buf, q_size, flags); imgui.NextColumn()
        imgui.InputText("##v_article" .. i .. unique_id, a_buf, a_size, flags); imgui.NextColumn()
        imgui.InputText("##v_brand" .. i .. unique_id, b_buf, b_size, flags); imgui.NextColumn()
        imgui.InputText("##v_model" .. i .. unique_id, m_buf, m_size, flags); imgui.NextColumn()
        imgui.InputText("##v_desc" .. i .. unique_id, d_buf, d_size, flags); imgui.NextColumn()
        imgui.PopItemWidth()
    end
    imgui.Columns(1)
    imgui.Separator()

    imgui.PopStyleColor(2)
    imgui.EndChild()
end

local function renderTCRViewer(record)
    local b = record.data
    if not b then return end
    local unique_id = tostring(record.id)

    imgui.BeginChild("TCRViewer" .. unique_id, imgui.new('ImVec2', 0, 0), false, imgui.WindowFlags.NoBackground)
    
    local flags = imgui.InputTextFlags.ReadOnly
    local gray_bg = imgui.ImVec4(0.95, 0.95, 0.95, 1.0)
    imgui.PushStyleColor(imgui.Col.FrameBg, gray_bg)
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.0, 0.0, 0.0, 1.0))

    local function create_viewer_buffer(text, size)
        size = size or 128
        local buf = imgui.new.char[size](text or '')
        return buf, ffi.sizeof(buf)
    end

    imgui.Text("Primary Information")
    imgui.Columns(3, "InfoColumnsViewer", false)
    local loc_buf, loc_size = create_viewer_buffer(b.location)
    imgui.Text("Location of Collision"); imgui.InputText("##v_location"..unique_id, loc_buf, loc_size, flags)
    imgui.NextColumn()
    local date_buf, date_size = create_viewer_buffer(b.date, 32)
    imgui.Text("Date"); imgui.InputText("##v_date"..unique_id, date_buf, date_size, flags)
    imgui.NextColumn()
    local time_buf, time_size = create_viewer_buffer(b.time, 32)
    imgui.Text("Time"); imgui.InputText("##v_time"..unique_id, time_buf, time_size, flags)
    imgui.Columns(1)

    imgui.Columns(2, "OfficerColumnsViewer", false)
    local officer_buf, officer_size = create_viewer_buffer(b.reporting_officer, 64)
    imgui.Text("Reporting Officer"); imgui.InputText("##v_officer"..unique_id, officer_buf, officer_size, flags)
    imgui.NextColumn()
    local badge_buf, badge_size = create_viewer_buffer(b.officer_serial, 32) 
    imgui.Text("Badge No."); imgui.InputText("##v_badge"..unique_id, badge_buf, badge_size, flags)
    imgui.Columns(1)
    imgui.Separator()

    imgui.Columns(2, "PartyColumnsViewer", false)
    imgui.Text("Party 1 (V-1)")
    local v1_name_buf, v1_name_size = create_viewer_buffer(b.v1_driver_name)
    imgui.InputText('Driver Name##V1', v1_name_buf, v1_name_size, flags)
    local v1_lic_buf, v1_lic_size = create_viewer_buffer(b.v1_driver_license, 64)
    imgui.InputText('License No.##V1', v1_lic_buf, v1_lic_size, flags)
    local v1_veh_buf, v1_veh_size = create_viewer_buffer(b.v1_vehicle_year_make)
    imgui.InputText('Vehicle Year/Make##V1', v1_veh_buf, v1_veh_size, flags)
    local v1_plate_buf, v1_plate_size = create_viewer_buffer(b.v1_vehicle_plate, 64)
    imgui.InputText('Plate No.##V1', v1_plate_buf, v1_plate_size, flags)
    local v1_ins_buf, v1_ins_size = create_viewer_buffer(b.v1_insurance)
    imgui.InputText('Insurance Co.##V1', v1_ins_buf, v1_ins_size, flags)
    imgui.NextColumn()

    imgui.Text("Party 2 (V-2)")
    local v2_name_buf, v2_name_size = create_viewer_buffer(b.v2_driver_name)
    imgui.InputText('Driver Name##V2', v2_name_buf, v2_name_size, flags)
    local v2_lic_buf, v2_lic_size = create_viewer_buffer(b.v2_driver_license, 64)
    imgui.InputText('License No.##V2', v2_lic_buf, v2_lic_size, flags)
    local v2_veh_buf, v2_veh_size = create_viewer_buffer(b.v2_vehicle_year_make)
    imgui.InputText('Vehicle Year/Make##V2', v2_veh_buf, v2_veh_size, flags)
    local v2_plate_buf, v2_plate_size = create_viewer_buffer(b.v2_vehicle_plate, 64)
    imgui.InputText('Plate No.##V2', v2_plate_buf, v2_plate_size, flags)
    local v2_ins_buf, v2_ins_size = create_viewer_buffer(b.v2_insurance)
    imgui.InputText('Insurance Co.##V2', v2_ins_buf, v2_ins_size, flags)
    imgui.Columns(1)
    imgui.Separator()

    imgui.Text("Collision Details")
    imgui.Columns(3, "ConditionsColumnsViewer", false)
    local ct_buf, ct_size = create_viewer_buffer(b.collision_type, 64)
    imgui.Text("Type of Collision"); imgui.InputText("##v_ct"..unique_id, ct_buf, ct_size, flags)
    imgui.NextColumn()
    local wc_buf, wc_size = create_viewer_buffer(b.weather_condition, 64)
    imgui.Text("Weather Conditions"); imgui.InputText("##v_wc"..unique_id, wc_buf, wc_size, flags)
    imgui.NextColumn()
    local rc_buf, rc_size = create_viewer_buffer(b.road_condition, 64)
    imgui.Text("Road Conditions"); imgui.InputText("##v_rc"..unique_id, rc_buf, rc_size, flags)
    imgui.Columns(1)
    imgui.Separator()

    imgui.Text('Narrative')
    imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0.95, 0.95, 0.95, 1.0))
    imgui.BeginChild("narrative_tcr_bg", imgui.new('ImVec2', -1, 100), true)
    imgui.TextWrapped(b.narrative or "")
    imgui.EndChild()
    imgui.PopStyleColor(1)
    imgui.Separator()

    imgui.Text("Conclusion & Actions Taken")
    local pcf_buf, pcf_size = create_viewer_buffer(b.pcf_factor, 256)
    imgui.InputText('Primary Collision Factor (PCF)', pcf_buf, pcf_size, flags)

    local injuries_b = imgui.new.bool(b.injuries or false)
    imgui.Checkbox('Injuries Reported', injuries_b)
    imgui.SameLine(200)
    local towed_b = imgui.new.bool(b.towed or false)
    imgui.Checkbox('Vehicle(s) Towed', towed_b)
    imgui.SameLine(400)
    local citations_b = imgui.new.bool(b.citations_issued or false)
    imgui.Checkbox('Citations Issued', citations_b)
    imgui.Separator()

    imgui.PopStyleColor(2)
    imgui.EndChild()
end

local function renderIncidentViewer(record)
    local b = record.data
    if not b then return end
    local unique_id = tostring(record.id)

    imgui.BeginChild("IncidentViewer" .. unique_id, imgui.new('ImVec2', 0, 0), false, imgui.WindowFlags.NoBackground)
    
    local flags = imgui.InputTextFlags.ReadOnly
    local gray_bg = imgui.ImVec4(0.95, 0.95, 0.95, 1.0)
    imgui.PushStyleColor(imgui.Col.FrameBg, gray_bg)
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.0, 0.0, 0.0, 1.0))

    local function create_viewer_buffer(text, size)
        size = size or 128
        local buf = imgui.new.char[size](tostring(text) or '')
        return buf, ffi.sizeof(buf)
    end

    imgui.Text("INCIDENT INFORMATION")
    imgui.Columns(4)
    local rdate_buf, rdate_size = create_viewer_buffer(b.report_date, 32)
    imgui.Text("Date of Report"); imgui.InputText("##v_rdate_inc"..unique_id, rdate_buf, rdate_size, flags); imgui.NextColumn()
    local rtime_buf, rtime_size = create_viewer_buffer(b.report_time, 32)
    imgui.Text("Time"); imgui.InputText("##v_rtime_inc"..unique_id, rtime_buf, rtime_size, flags); imgui.NextColumn()
    local idate_buf, idate_size = create_viewer_buffer(b.incident_date, 32)
    imgui.Text("Incident Date"); imgui.InputText("##v_idate_inc"..unique_id, idate_buf, idate_size, flags); imgui.NextColumn()
    local itime_buf, itime_size = create_viewer_buffer(b.incident_time, 32)
    imgui.Text("Incident Time"); imgui.InputText("##v_itime_inc"..unique_id, itime_buf, itime_size, flags); imgui.NextColumn()
    imgui.Columns(1)

    local loc_buf, loc_size = create_viewer_buffer(b.location)
    imgui.InputText("Location of Occurrence", loc_buf, loc_size, flags)
    local type_buf, type_size = create_viewer_buffer(b.incident_type)
    imgui.InputText("Incident Type (UCR Code & Description)", type_buf, type_size, flags)
    imgui.Separator()

    imgui.Text("INVOLVED PERSONS (V = Victim, S = Suspect, W = Witness)")
    imgui.Columns(6, "PersonsHeaderViewer")
    imgui.Text("Type"); imgui.NextColumn()
    imgui.Text("Name (Last, First)"); imgui.NextColumn()
    imgui.Text("D.O.B."); imgui.NextColumn()
    imgui.Text("Sex"); imgui.NextColumn()
    imgui.Text("Desc"); imgui.NextColumn()
    imgui.Text("Phone"); imgui.NextColumn()
    imgui.Separator()
    for i, person in ipairs(b.persons) do
        imgui.PushItemWidth(-1)
        local ptype_buf, ptype_size = create_viewer_buffer(person.type, 8)
        imgui.InputText("##v_ptype"..i..unique_id, ptype_buf, ptype_size, flags); imgui.NextColumn()
        local pname_buf, pname_size = create_viewer_buffer(person.name)
        imgui.InputText("##v_pname"..i..unique_id, pname_buf, pname_size, flags); imgui.NextColumn()
        local pdob_buf, pdob_size = create_viewer_buffer(person.dob, 32)
        imgui.InputText("##v_pdob"..i..unique_id, pdob_buf, pdob_size, flags); imgui.NextColumn()
        local psex_buf, psex_size = create_viewer_buffer(person.sex, 8)
        imgui.InputText("##v_psex"..i..unique_id, psex_buf, psex_size, flags); imgui.NextColumn()
        local pdesc_buf, pdesc_size = create_viewer_buffer(person.desc, 8)
        imgui.InputText("##v_pdesc"..i..unique_id, pdesc_buf, pdesc_size, flags); imgui.NextColumn()
        local pphone_buf, pphone_size = create_viewer_buffer(person.phone, 64)
        imgui.InputText("##v_pphone"..i..unique_id, pphone_buf, pphone_size, flags); imgui.NextColumn()
        imgui.PopItemWidth()
    end
    imgui.Columns(1)
    imgui.Separator()

    imgui.Text("PROPERTY (Stolen, Damaged, Evidence, etc.)")
    imgui.Columns(4, "PropertyHeaderViewer")
    imgui.Text("Code"); imgui.NextColumn()
    imgui.Text("Article"); imgui.NextColumn()
    imgui.Text("Description / Serial No."); imgui.NextColumn()
    imgui.Text("Value ($)"); imgui.NextColumn()
    imgui.Separator()
    for i, prop in ipairs(b.property) do
        imgui.PushItemWidth(-1)
        local pcode_buf, pcode_size = create_viewer_buffer(prop.code, 16)
        imgui.InputText("##v_pcode"..i..unique_id, pcode_buf, pcode_size, flags); imgui.NextColumn()
        local particle_buf, particle_size = create_viewer_buffer(prop.article)
        imgui.InputText("##v_particle"..i..unique_id, particle_buf, particle_size, flags); imgui.NextColumn()
        local pdesc_buf, pdesc_size = create_viewer_buffer(prop.description, 256)
        imgui.InputText("##v_pdesc"..i..unique_id, pdesc_buf, pdesc_size, flags); imgui.NextColumn()
        local pvalue_buf, pvalue_size = create_viewer_buffer(prop.value, 32)
        imgui.InputText("##v_pvalue"..i..unique_id, pvalue_buf, pvalue_size, flags); imgui.NextColumn()
        imgui.PopItemWidth()
    end
    imgui.Columns(1)
    imgui.Separator()

    imgui.Text("MODUS OPERANDI (How was the crime committed?)")
    local mo_buf, mo_size = create_viewer_buffer(b.modus_operandi, 512)
    imgui.InputTextMultiline("##mo", mo_buf, mo_size, imgui.new('ImVec2', -1, 40), flags)
    imgui.Separator()
    imgui.Text("NARRATIVE (Chronological account of events andactions taken)")
    imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0.95, 0.95, 0.95, 1.0))
    imgui.BeginChild("narrative_inc_bg", imgui.new('ImVec2', -1, 100), true)
    imgui.TextWrapped(b.narrative or "")
    imgui.EndChild()
    imgui.PopStyleColor(1)
    imgui.Separator()

    imgui.Columns(3)
    local rofficer_buf, rofficer_size = create_viewer_buffer(b.reporting_officer, 64)
    imgui.InputText("Reporting Officer", rofficer_buf, rofficer_size, flags); imgui.NextColumn()
    local rserial_buf, rserial_size = create_viewer_buffer(b.officer_serial, 32)
    imgui.InputText("Serial No.", rserial_buf, rserial_size, flags); imgui.NextColumn()
    local status_text = "Unknown"
    if b.case_status == 0 then status_text = "Active"
    elseif b.case_status == 1 then status_text = "Suspended"
    elseif b.case_status == 2 then status_text = "Closed"
    end
    imgui.Text("Case Status: " .. (b.case_status or "Unknown"))
    imgui.NextColumn()
    imgui.Columns(1)

    imgui.PopStyleColor(2)
    imgui.EndChild()
end

local function renderFollowUpViewer(record)
    local b = record.data
    if not b then return end
    local unique_id = tostring(record.id)

    imgui.BeginChild("FollowUpViewer" .. unique_id, imgui.new('ImVec2', 0, 0), false, imgui.WindowFlags.NoBackground)
    
    local flags = imgui.InputTextFlags.ReadOnly
    local gray_bg = imgui.ImVec4(0.95, 0.95, 0.95, 1.0)
    imgui.PushStyleColor(imgui.Col.FrameBg, gray_bg)
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.0, 0.0, 0.0, 1.0))

    local function create_viewer_buffer(text, size)
        size = size or 256
        local buf = imgui.new.char[size](tostring(text) or '')
        return buf, ffi.sizeof(buf)
    end

    
    imgui.Columns(2, "HeaderInfo", false)
    imgui.SetColumnWidth(0, 320)
    local rdate_buf, rdate_size = create_viewer_buffer(b.report_date)
    imgui.Text("DATE OF THIS REPORT")
    imgui.InputText("##v_rdate"..unique_id, rdate_buf, rdate_size, flags)
    
    local ort_buf, ort_size = create_viewer_buffer(b.selected_report_type)
    imgui.Text("ORIGINAL REPORT TYPE")
    imgui.InputText("##v_ort"..unique_id, ort_buf, ort_size, flags)
    imgui.NextColumn()

    local odate_buf, odate_size = create_viewer_buffer(b.original_report_date)
    imgui.Text("ORIGINAL REPORT DATE")
    imgui.InputText("##v_odate"..unique_id, odate_buf, odate_size, flags)
    
    local is_multiple_b = imgui.new.bool(b.is_multiple or false)
    imgui.Dummy(imgui.new('ImVec2', 0, 5)) 
    imgui.Checkbox('MULTIPLE', is_multiple_b)
    imgui.Columns(1)

    imgui.Columns(2, "VictimInfo", false)
    imgui.SetColumnWidth(0, 450)
    local victim_buf, victim_size = create_viewer_buffer(b.victim_booked_to)
    imgui.Text("VICTIM / PERSON BOOKED")
    imgui.InputText("##v_victim"..unique_id, victim_buf, victim_size, flags)
    imgui.NextColumn()
    local wfid_buf, wfid_size = create_viewer_buffer(b.work_folder_id)
    imgui.Text("WORK FOLDER I.D.")
    imgui.InputText("##v_wfid"..unique_id, wfid_buf, wfid_size, flags)
    imgui.Columns(1)
    
    imgui.Separator()
    local case_status_text = "Investigation Continuing"
    if b.case_status == 1 then case_status_text = "Cleared by Arrest"
    elseif b.case_status == 2 then case_status_text = "Cleared Otherwise"
    elseif b.case_status == 3 then case_status_text = "Report Unfounded"
    end
    imgui.Text('CASE STATUS: ' .. case_status_text)
    imgui.Separator()

    imgui.Columns(11, 'personsColumnsViewer', true)
    
    local col_widths = {25, 35, 40, 40, 40, 35, 35, 90, 35}
    local fixed_width_sum = 0
    for i = 1, #col_widths do
        imgui.SetColumnWidth(i - 1, col_widths[i])
        fixed_width_sum = fixed_width_sum + col_widths[i]
    end

    local remaining_width = imgui.GetContentRegionAvail().x - fixed_width_sum
    
    
    
    local name_charge_width = math.max(150, remaining_width * 0.55)
    local action_taken_width = math.max(150, remaining_width * 0.45)
    
    imgui.SetColumnWidth(9, name_charge_width)
    imgui.SetColumnWidth(10, action_taken_width)

    
    imgui.Text('S'); imgui.NextColumn()
    imgui.Text('SEX'); imgui.NextColumn()
    imgui.Text('DESC'); imgui.NextColumn()
    imgui.Text('HAIR'); imgui.NextColumn()
    imgui.Text('EYES'); imgui.NextColumn()
    imgui.Text('HGT'); imgui.NextColumn()
    imgui.Text('WGT'); imgui.NextColumn()
    imgui.Text('D.O.B.'); imgui.NextColumn()
    imgui.Text('AGE'); imgui.NextColumn()
    imgui.Text('NAME / CHARGE'); imgui.NextColumn()
    imgui.Text('ACTION TAKEN'); imgui.NextColumn()
    imgui.Separator()

    
    if b.persons and type(b.persons) == 'table' then
        for i, person in ipairs(b.persons) do
            imgui.Text(person.s_type or ""); imgui.NextColumn()
            imgui.Text(person.sex or ""); imgui.NextColumn()
            imgui.Text(person.desc or ""); imgui.NextColumn()
            imgui.Text(person.hair or ""); imgui.NextColumn()
            imgui.Text(person.eyes or ""); imgui.NextColumn()
            imgui.Text(person.height or ""); imgui.NextColumn()
            imgui.Text(person.weight or ""); imgui.NextColumn()
            imgui.Text(person.dob or ""); imgui.NextColumn()
            imgui.Text(person.age or ""); imgui.NextColumn()

            local name_buf, name_size = create_viewer_buffer(person.name_address)
            imgui.InputText('##v_name'..i..unique_id, name_buf, name_size, flags); imgui.NextColumn()

            local action_buf, action_size = create_viewer_buffer(person.action_taken)
            imgui.InputText('##v_action'..i..unique_id, action_buf, action_size, flags); imgui.NextColumn()
        end
    end
    imgui.Columns(1)

    
    imgui.Separator()
    imgui.Text('NARRATIVE / FOLLOW-UP REPORT')
    imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0.95, 0.95, 0.95, 1.0))
    imgui.BeginChild("narrative_fu_bg", imgui.new('ImVec2', -1, 100), true)
    imgui.TextWrapped(b.narrative or "")
    imgui.EndChild()
    imgui.PopStyleColor(1)

    imgui.Separator()
    local prop_booked_b = imgui.new.bool(b.property_booked or false)
    imgui.Checkbox('PROPERTY BOOKED', prop_booked_b)
    imgui.SameLine()
    local form_1608_b = imgui.new.bool(b.form_16_08_completed or false)
    imgui.Checkbox('IF YES, FORM 16.08 COMPLETED?', form_1608_b)

    imgui.Separator()
    imgui.Columns(3, "OfficerInfo", false)
    local rofficer_buf, rofficer_size = create_viewer_buffer(b.reporting_officer)
    imgui.Text("REPORTING OFFICER")
    imgui.InputText('##v_rofficer'..unique_id, rofficer_buf, rofficer_size, flags)
    imgui.NextColumn()
    
    local rserial_buf, rserial_size = create_viewer_buffer(b.officer_serial)
    imgui.Text("SERIAL NO.")
    imgui.InputText('##v_rserial'..unique_id, rserial_buf, rserial_size, flags)
    imgui.NextColumn()

    local rdiv_buf, rdiv_size = create_viewer_buffer(b.officer_division)
    imgui.Text("DIVISION/DETAIL")
    imgui.InputText('##v_rdiv'..unique_id, rdiv_buf, rdiv_size, flags)
    imgui.Columns(1)

    imgui.PopStyleColor(2)
    imgui.EndChild()
end

local function renderComplaintViewer(record)
    local b = record.data
    if not b then return end
    local unique_id = tostring(record.id)

    imgui.BeginChild("ComplaintViewer" .. unique_id, imgui.new('ImVec2', 0, 0), false, imgui.WindowFlags.NoBackground)
    
    local flags = imgui.InputTextFlags.ReadOnly
    local gray_bg = imgui.ImVec4(0.95, 0.95, 0.95, 1.0)
    imgui.PushStyleColor(imgui.Col.FrameBg, gray_bg)
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.0, 0.0, 0.0, 1.0))

    local function create_viewer_buffer(text, size)
        size = size or 128
        local buf = imgui.new.char[size](tostring(text) or '')
        return buf, ffi.sizeof(buf)
    end

    imgui.Text("Complainant Information")
    imgui.Columns(2, "complainant_info_viewer")
    local cname_buf, cname_size = create_viewer_buffer(b.c_name)
    imgui.InputText("Name (Last, First)", cname_buf, cname_size, flags)
    local caddr_buf, caddr_size = create_viewer_buffer(b.c_address, 256)
    imgui.InputText("Address", caddr_buf, caddr_size, flags)
    imgui.NextColumn()
    local cphone_buf, cphone_size = create_viewer_buffer(b.c_phone, 64)
    imgui.InputText("Phone Number", cphone_buf, cphone_size, flags)
    local cdob_buf, cdob_size = create_viewer_buffer(b.c_dob, 32)
    imgui.InputText("Date of Birth", cdob_buf, cdob_size, flags)
    imgui.Columns(1)
    imgui.Separator()
    imgui.Text("Incident Details")
    local itype_buf, itype_size = create_viewer_buffer(b.incident_type)
    imgui.InputText("Type of Incident", itype_buf, itype_size, flags)
    imgui.Columns(2, "incident_details_viewer")
    local idate_buf, idate_size = create_viewer_buffer(b.incident_date_occurred, 32)
    imgui.InputText("Date Occurred", idate_buf, idate_size, flags)
    imgui.NextColumn()
    local itime_buf, itime_size = create_viewer_buffer(b.incident_time_occurred, 32)
    imgui.InputText("Time Occurred", itime_buf, itime_size, flags)
    imgui.Columns(1)
    local iloc_buf, iloc_size = create_viewer_buffer(b.incident_location, 256)
    imgui.InputText("Location of Incident", iloc_buf, iloc_size, flags)

    imgui.Separator()
    imgui.Text("Narrative / Statement of Complainant")
    imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0.95, 0.95, 0.95, 1.0))
    imgui.BeginChild("narrative_comp_bg", imgui.new('ImVec2', -1, 100), true)
    imgui.TextWrapped(b.narrative or "")
    imgui.EndChild()
    imgui.PopStyleColor(1)
    imgui.Separator()
    imgui.Columns(2, "involved_things_viewer")
    imgui.Text("Persons Involved")
    imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0.95, 0.95, 0.95, 1.0))
    imgui.BeginChild("persons_comp_bg", imgui.new('ImVec2', -1, 80), true)
    imgui.TextWrapped(b.involved_persons or "")
    imgui.EndChild()
    imgui.PopStyleColor(1)
    imgui.NextColumn()
    imgui.Text("Property Involved")
    imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0.95, 0.95, 0.95, 1.0))
    imgui.BeginChild("property_comp_bg", imgui.new('ImVec2', -1, 80), true)
    imgui.TextWrapped(b.involved_property or "")
    imgui.EndChild()
    imgui.PopStyleColor(1)
    imgui.Columns(1)

    imgui.Separator()
    imgui.Columns(2, "officer_info_viewer")
    local officer_buf, officer_size = create_viewer_buffer(b.reporting_officer, 64)
    imgui.InputText("Reporting Officer", officer_buf, officer_size, flags)
    imgui.NextColumn()
    local serial_buf, serial_size = create_viewer_buffer(b.officer_serial, 32)
    imgui.InputText("Serial No.", serial_buf, serial_size, flags)
    imgui.Columns(1)

    imgui.PopStyleColor(2)
    imgui.EndChild()
end

local function renderCCWSuspensionViewer(record)
    local b = record.data
    if not b then return end
    local unique_id = tostring(record.id)

    imgui.BeginChild("CCWViewer" .. unique_id, imgui.new('ImVec2', 0, 0), false, imgui.WindowFlags.NoBackground)
    
    local flags = imgui.InputTextFlags.ReadOnly
    local gray_bg = imgui.ImVec4(0.95, 0.95, 0.95, 1.0)
    imgui.PushStyleColor(imgui.Col.FrameBg, gray_bg)
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.0, 0.0, 0.0, 1.0))

    local function create_viewer_buffer(text, size)
        size = size or 128
        local buf = imgui.new.char[size](tostring(text) or '')
        return buf, ffi.sizeof(buf)
    end

    imgui.Text("License Holder Information")
    imgui.Columns(2, "lh_info_viewer")
    local lhname_buf, lhname_size = create_viewer_buffer(b.lh_name)
    imgui.InputText("Name (Last, First)", lhname_buf, lhname_size, flags)
    local lhaddr_buf, lhaddr_size = create_viewer_buffer(b.lh_address, 256)
    imgui.InputText("Address", lhaddr_buf, lhaddr_size, flags)
    imgui.NextColumn()
    local lhdob_buf, lhdob_size = create_viewer_buffer(b.lh_dob, 32)
    imgui.InputText("Date of Birth", lhdob_buf, lhdob_size, flags)
    local lhlic_buf, lhlic_size = create_viewer_buffer(b.lh_license_number, 64)
    imgui.InputText("CCW License Number", lhlic_buf, lhlic_size, flags)
    imgui.Columns(1)
    imgui.Separator()

    imgui.Text("Reason for Suspension / Revocation")
    local reason_buf, reason_size = create_viewer_buffer(b.suspension_reason, 256)
    imgui.InputText("##v_reason_ccw", reason_buf, reason_size, flags)

    imgui.Columns(2, "seizure_details_viewer")
    local sdate_buf, sdate_size = create_viewer_buffer(b.seizure_date, 32)
    imgui.InputText("Date of Seizure", sdate_buf, sdate_size, flags)
    imgui.NextColumn()
    local stime_buf, stime_size = create_viewer_buffer(b.seizure_time, 32)
    imgui.InputText("Time of Seizure", stime_buf, stime_size, flags)
    imgui.Columns(1)
    
    imgui.Text("Firearms Seized (Make, Model, Serial No.)")
    imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0.95, 0.95, 0.95, 1.0))
    imgui.BeginChild("firearms_ccw_bg", imgui.new('ImVec2', -1, 60), true)
    imgui.TextWrapped(b.seized_firearms or "")
    imgui.EndChild()
    imgui.PopStyleColor(1)
    imgui.Separator()
    
    imgui.Text("Related Incident Information")
    local rel_dr_buf, rel_dr_size = create_viewer_buffer(b.related_dr_no, 32)
    imgui.InputText("Related DR No.", rel_dr_buf, rel_dr_size, flags)
    imgui.Text("Incident Summary")
    imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0.95, 0.95, 0.95, 1.0))
    imgui.BeginChild("summary_ccw_bg", imgui.new('ImVec2', -1, 80), true)
    imgui.TextWrapped(b.incident_summary or "")
    imgui.EndChild()
    imgui.PopStyleColor(1)

    imgui.Columns(2, "officer_final_viewer")
    local officer_buf, officer_size = create_viewer_buffer(b.reporting_officer, 64)
    imgui.InputText("Reporting Officer", officer_buf, officer_size, flags)
    imgui.NextColumn()
    local serial_buf, serial_size = create_viewer_buffer(b.officer_serial, 32)
    imgui.InputText("Serial No.", serial_buf, serial_size, flags)
    imgui.Columns(1)
    local sig_b = imgui.new.bool(b.supervisor_signature)
    imgui.Checkbox("Supervisor Notified and Concurs", sig_b)
    imgui.Separator()

    imgui.PopStyleColor(2)
    imgui.EndChild()
end

local function renderPropertyReportViewer(record)
    local b = record.data
    if not b then return end
    local unique_id = tostring(record.id)

    imgui.BeginChild("PropertyViewer" .. unique_id, imgui.new('ImVec2', 0, 0), false, imgui.WindowFlags.NoBackground)
    
    local flags = imgui.InputTextFlags.ReadOnly
    local gray_bg = imgui.ImVec4(0.95, 0.95, 0.95, 1.0)
    imgui.PushStyleColor(imgui.Col.FrameBg, gray_bg)
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.0, 0.0, 0.0, 1.0))

    local function create_viewer_buffer(text, size)
        size = size or 128
        local buf = imgui.new.char[size](tostring(text) or '')
        return buf, ffi.sizeof(buf)
    end

    imgui.Text("Owner Information")
    local oname_buf, oname_size = create_viewer_buffer(b.owner_name)
    imgui.InputText("Name (Last, First)", oname_buf, oname_size, flags)
    local oaddr_buf, oaddr_size = create_viewer_buffer(b.owner_address, 256)
    imgui.InputText("Address", oaddr_buf, oaddr_size, flags)
    local ophone_buf, ophone_size = create_viewer_buffer(b.owner_phone, 64)
    imgui.InputText("Phone Number", ophone_buf, ophone_size, flags)
    imgui.Separator()
    
    imgui.Text("Reason for Booking: " .. (b.booking_reason or "N/A"))
    imgui.Separator()

    imgui.Text("Booked Property List")
    imgui.Columns(3, "PropertyItemsViewer", true)
    imgui.Text("Quant."); imgui.NextColumn()
    imgui.Text("Description"); imgui.NextColumn()
    imgui.Text("Value ($)"); imgui.NextColumn()
    imgui.Separator()

    for i, item in ipairs(b.items) do
        imgui.PushItemWidth(-1)
        local quant_buf, quant_size = create_viewer_buffer(item.quant, 8)
        imgui.InputText("##v_quant_prop"..i..unique_id, quant_buf, quant_size, flags); imgui.NextColumn()
        local desc_buf, desc_size = create_viewer_buffer(item.description, 256)
        imgui.InputText("##v_desc_prop"..i..unique_id, desc_buf, desc_size, flags); imgui.NextColumn()
        local value_buf, value_size = create_viewer_buffer(item.value, 32)
        imgui.InputText("##v_value_prop"..i..unique_id, value_buf, value_size, flags); imgui.NextColumn()
        imgui.PopItemWidth()
    end
    imgui.Columns(1)
    imgui.Separator()

    imgui.Text("Narrative (Circumstances of booking)")
    imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0.95, 0.95, 0.95, 1.0))
    imgui.BeginChild("narrative_prop_bg", imgui.new('ImVec2', -1, 80), true)
    imgui.TextWrapped(b.narrative or "")
    imgui.EndChild()
    imgui.PopStyleColor(1)
    imgui.Separator()

    imgui.Columns(2, "officer_info_prop_viewer")
    local officer_buf, officer_size = create_viewer_buffer(b.reporting_officer, 64)
    imgui.InputText("Reporting Officer", officer_buf, officer_size, flags)
    imgui.NextColumn()
    local serial_buf, serial_size = create_viewer_buffer(b.officer_serial, 32)
    imgui.InputText("Serial No.", serial_buf, serial_size, flags)
    imgui.Columns(1)

    imgui.PopStyleColor(2)
    imgui.EndChild()
end

local function renderFolderViewer(folder)
    imgui.Text("Folder Contents: " .. (folder.primary_person or "Unnamed Folder"))
    imgui.Separator()

    
    if not folder.items or #folder.items == 0 then
        imgui.Text("This folder is empty.")
    else
        for i, record_item in ipairs(folder.items) do
            
            if not record_item.display_name then
                local person_info = record_item.primary_person or "N/A"
                if record_item.secondary_info and record_item.secondary_info ~= "" then
                    person_info = person_info .. " / " .. record_item.secondary_info
                end
                record_item.display_name = string.format("%s - %s (%s)", record_item.record_type, record_item.dr_no, person_info)
            end

            
            if imgui.Selectable(escape_percents(record_item.display_name), recordsState.selected_record_item == record_item) then
                recordsState.selected_record_item = record_item 
                if not record_item.data then
                    requestReportDetails(record_item) 
                end
            end
        end
    end
end

local function renderCodebookWindow()
    if not active_codebook_view then return end

    local p_open = imgui.new.bool(true)
    local title = active_codebook_view == 'Penal' and "Penal Code" or "Traffic Code"
    
    
    
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(1.0, 1.0, 1.0, 1.0))
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.0, 0.0, 0.0, 1.0))
    
    imgui.SetNextWindowSize(imgui.new('ImVec2', 1100, 700), imgui.Cond.FirstUseEver)
    if imgui.Begin(title, p_open) then
        local data_source = active_codebook_view == 'Penal' and penal_code_data or traffic_code_data
        local search_buffer = active_codebook_view == 'Penal' and penal_search_query or traffic_search_query
        
        
        imgui.Text("Search:")
        imgui.SameLine()
        imgui.PushItemWidth(-1)
        
        imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0.9, 0.9, 0.9, 1.0))
        imgui.InputText("##code_search", search_buffer, ffi.sizeof(search_buffer))
        imgui.PopStyleColor(1) 
        imgui.PopItemWidth()
        imgui.Separator()

        
        imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(1.0, 1.0, 1.0, 1.0))
        imgui.BeginChild("CodeListScroll", imgui.new('ImVec2', 0, 0), false)

            
            imgui.Columns(3, "CodeColumns", true)
            imgui.SetColumnWidth(0, 120)
            imgui.SetColumnWidth(1, imgui.GetWindowWidth() - 260)
            imgui.SetColumnWidth(2, 110)

            
            imgui.Text("Code Section")
            imgui.NextColumn()
            imgui.Text("Description")
            imgui.NextColumn()
            imgui.Text(active_codebook_view == 'Penal' and "Class" or "Base Fine")
            imgui.NextColumn()
            imgui.Separator()

            
            local search_text = ffi.string(search_buffer):lower()
            for _, entry in ipairs(data_source) do
                local entry_text_code = (entry.code or ""):lower()
                local entry_text_desc = (entry.description or ""):lower()
                
                if search_text == "" or entry_text_code:find(search_text, 1, true) or entry_text_desc:find(search_text, 1, true) then
                    imgui.Text(entry.code)
                    imgui.NextColumn()
                    
                    imgui.TextWrapped(entry.description)
                    imgui.NextColumn()
                    
                    imgui.Text(active_codebook_view == 'Penal' and entry.class or entry.fine)
                    imgui.NextColumn()
                end
            end

            imgui.Columns(1)
        imgui.EndChild()
        imgui.PopStyleColor(1) 

    end
    imgui.End()
    
    imgui.PopStyleColor(2) 
    

    if not p_open[0] then
        active_codebook_view = nil
    end
end

local function renderDashboard()
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.0, 0.0, 0.0, 1.0))

    
    local user_name = (core and core.current_user and core.current_user.full_name) and core.current_user.full_name or "Officer"
    imgui.Text(string.format("Welcome back, %s!", user_name))
    imgui.Text("Current Time: " .. os.date("%H:%M:%S, %A, %x"))
    imgui.Separator()
    imgui.Spacing()

    if not dashboardState.data_loaded then
        imgui.Text("Loading dashboard data...")
        imgui.PopStyleColor(1)
        return
    end

    

    
    
    
    local stats_col_width = 220
    local my_reports_col_width = 280 

    
    imgui.BeginGroup() 
        imgui.Text("Quick Stats")
        imgui.Separator()
        imgui.BulletText(string.format("Reports created today: %d", dashboardState.stats.reports_today or 0))
        imgui.BulletText(string.format("Reports this week: %d", dashboardState.stats.reports_this_week or 0))
        imgui.BulletText(string.format("Total active cases: %d", dashboardState.stats.active_cases or 0))
        imgui.BulletText(string.format("Your submitted reports: %d", dashboardState.stats.my_reports or 0))
    imgui.EndGroup()

    imgui.SameLine() 
    imgui.SetCursorPosX(imgui.GetCursorPosX() + 20) 

    
    imgui.BeginGroup()
        imgui.Text("My Latest Reports")
        imgui.Separator()
        imgui.BeginChild("MyReportsChild", imgui.new('ImVec2', my_reports_col_width, 150), true) 
        if dashboardState.my_latest_reports and #dashboardState.my_latest_reports > 0 then
            for _, report in ipairs(dashboardState.my_latest_reports) do
                local report_text = string.format("[%s] %s - %s",
                    escape_percents(report.date or "??.??.????"),
                    escape_percents(report.report_type or "?"),
                    escape_percents(report.dr_no or "#?"))
                imgui.Text(report_text)
            end
        else
            imgui.Text("You have not created any reports yet.")
        end
        imgui.EndChild()
    imgui.EndGroup()

    imgui.SameLine() 
    imgui.SetCursorPosX(imgui.GetCursorPosX() + 20) 

    
    imgui.BeginGroup()
        imgui.Text("Recent System Activity")
        imgui.Separator()
        
        imgui.BeginChild("RecentActivityChild", imgui.new('ImVec2', 0, 150), true)
        if dashboardState.recent_activity and #dashboardState.recent_activity > 0 then
            for _, activity in ipairs(dashboardState.recent_activity) do
                local activity_text = string.format("[%s] %s created %s report %s",
                    escape_percents(activity.time or "??:??"),
                    escape_percents(activity.officer_name or "Unknown"),
                    escape_percents(activity.report_type or "a"),
                    escape_percents(activity.dr_no or "#?"))
                imgui.TextWrapped(activity_text)
            end
        else
            imgui.Text("No recent activity to display.")
        end
        imgui.EndChild()
    imgui.EndGroup()

    

    imgui.Spacing()
    imgui.Separator()

    imgui.Text("Code Reference:")
    imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.9, 0.9, 0.9, 1.0))
    if imgui.Button("Penal Code", imgui.new('ImVec2', 130, 30)) then
        active_codebook_view = 'Penal'
    end
    imgui.SameLine()
    if imgui.Button("Traffic Code", imgui.new('ImVec2', 130, 30)) then
        active_codebook_view = 'Traffic'
    end
    imgui.PopStyleColor(1)

    imgui.PopStyleColor(1)
end

renderRMSWindow = function()
    collectgarbage("stop")

    imgui.PushStyleColor(imgui.Col.PopupBg, imgui.ImVec4(0.4, 0.4, 0.4, 0.95))

    if not UI.rms_window or not UI.rms_window[0] then
        if active_rms_form then switchRMSForm(nil) end
        if recordsState.selected_record then recordsState.selected_record = nil end
        if recordsState.groupingMode then
            recordsState.groupingMode = false
            recordsState.selectedForGrouping = {}
            recordsState.isNamingFolder = false 
        end
        collectgarbage("restart")
        imgui.PopStyleColor(1)
        return
    end

    imgui.SetNextWindowSize(imgui.new('ImVec2', 1400, 750), imgui.Cond.FirstUseEver)
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(1.0, 1.0, 1.0, 1.0));
    imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(1.0, 1.0, 1.0, 1.0));

    if imgui.Begin("Records Management System", UI.rms_window) then
        imgui.Columns(2, "RMSLayout", true)
        imgui.SetColumnWidth(0, 250)

        
        imgui.BeginChild("RecordList", imgui.new('ImVec2', 0, 0), true)
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.0, 0.0, 0.0, 1.0))
            
            imgui.Text(recordsState.groupingMode and "Select Reports to Group" or "Records List")
            imgui.Separator()

            
            if recordsState.groupingMode then
                imgui.Text("Search by DR No. or Name:")
                imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0.9, 0.9, 0.9, 1.0))
                imgui.PushItemWidth(-1)
                imgui.InputText("##group_search", recordsState.group_search_query, ffi.sizeof(recordsState.group_search_query))
                imgui.PopItemWidth()
                imgui.PopStyleColor(1)
                imgui.Separator()
            else
                imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0.9, 0.9, 0.9, 1.0))
                imgui.PushStyleColor(imgui.Col.HeaderHovered, imgui.ImVec4(0.8, 0.8, 0.8, 1.0))
                imgui.PushStyleColor(imgui.Col.HeaderActive, imgui.ImVec4(0.7, 0.7, 0.7, 1.0))
                imgui.Text("Filter by type:")
                imgui.PushItemWidth(-1)
                imgui.Combo("##typefilter", recordsState.filter_index, recordsState_types_c, #recordsState.types)
                imgui.PopItemWidth()
                imgui.PopStyleColor(3)
                imgui.Separator()
                imgui.Text("Search by DR No. or Name:")
                imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0.9, 0.9, 0.9, 1.0))
                imgui.PushItemWidth(-1)
                imgui.InputText("##search", recordsState.search_query, ffi.sizeof(recordsState.search_query))
                imgui.PopItemWidth()
                imgui.PopStyleColor(1)
                if imgui.Button("Refresh", imgui.new('ImVec2', -1, 0)) then
                    requestReportsList()
                end
                imgui.Separator()
            end

            local selected_type = recordsState.types[recordsState.filter_index[0] + 1]
            local search_text = ffi.string(recordsState.search_query):lower()
            local group_search_text = ffi.string(recordsState.group_search_query):lower()

            for i, record in ipairs(recordsState.records) do
                if recordsState.groupingMode then
                    if record.record_type ~= "Folder" then
                        local group_search_match = (group_search_text == "" or (record.dr_no .. " " .. (record.primary_person or "")):lower():find(group_search_text, 1, true))
                        if group_search_match then
                            local is_selected = imgui.new.bool(recordsState.selectedForGrouping[record.id] or false)
                            if imgui.Checkbox(escape_percents(record.display_name), is_selected) then
                                recordsState.selectedForGrouping[record.id] = is_selected[0]
                            end
                        end
                    end
                else
                    
                    
                    local type_match = (selected_type == "All" or record.record_type == selected_type)
                    local search_match = (search_text == "" or (record.dr_no .. " " .. (record.primary_person or "")):lower():find(search_text, 1, true))

                    if type_match and search_match then
                        if imgui.Selectable(escape_percents(record.display_name or "N/A"), recordsState.selected_record == record) then
                            recordsState.selected_record = record
                            recordsState.selected_record_item = nil 
                            if record.record_type ~= "Folder" and not record.data then
                                requestReportDetails(record)
                            end
                            if active_rms_form then switchRMSForm(nil) end
                        end
                    end
                end
            end
            
            imgui.PopStyleColor(1)
        imgui.EndChild()

        imgui.NextColumn()

        
        imgui.BeginChild("ContentArea", imgui.new('ImVec2', 0, 0), false)
            if recordsState.groupingMode then
                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.0, 0.0, 0.0, 1.0))
                imgui.Text("Folder Management")
                imgui.Separator()

                local selection_count = 0
                for _, selected in pairs(recordsState.selectedForGrouping) do
                    if selected then selection_count = selection_count + 1 end
                end
                imgui.Text(string.format("Selected %d report(s).", selection_count))
                
                if selection_count > 0 then
                    imgui.Separator()
                    imgui.Text("New folder name:")
                    imgui.PushItemWidth(300)
                    imgui.InputText("##foldername", folderNameBuffer, 128)
                    imgui.PopItemWidth()

                    if imgui.Button("Create Folder", imgui.new('ImVec2', 150, 0)) then
                        local folder_name_str = ffi.string(folderNameBuffer)
                        if folder_name_str ~= "" and selection_count > 0 then
                            local report_ids_to_group = {}
                            for record_id, is_selected in pairs(recordsState.selectedForGrouping) do
                                if is_selected then
                                    table.insert(report_ids_to_group, record_id)
                                end
                            end
                            
                            if #report_ids_to_group > 0 then
                                log('RMS', log_levels.INFO, string.format("Sending request to create folder '%s' with %d reports", folder_name_str, #report_ids_to_group))
                                
                                local request = {
                                    type = 'rms',
                                    action = 'create_folder',
                                    token = core.auth_token,
                                    payload = {
                                        folderName = folder_name_str,
                                        reportIds = report_ids_to_group
                                    }
                                }
                                websocket.send(request)
                                
                                recordsState.groupingMode = false
                                recordsState.selectedForGrouping = {}
                                ffi.copy(recordsState.group_search_query, '', 128)
                                ffi.copy(folderNameBuffer, 'New Folder', 128)
                            else
                                log('RMS', log_levels.WARN, "No reports selected to group.")
                            end
                        end
                    end
                end

                imgui.Separator()
                if imgui.Button("Cancel Grouping", imgui.new('ImVec2', 150, 0)) then
                    recordsState.groupingMode = false
                    recordsState.selectedForGrouping = {}
                    ffi.copy(recordsState.group_search_query, '', 128)
                end

                imgui.PopStyleColor(1)
            elseif recordsState.selected_record then
                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.0, 0.0, 0.0, 1.0))
                
                local preview_name = recordsState.selected_record and recordsState.selected_record.display_name or "N/A"
                imgui.Text(string.format("Record Preview: %s", preview_name))
                imgui.SameLine(imgui.GetContentRegionAvail().x - 120)
                if imgui.Button("Close Preview") then
                    recordsState.selected_record = nil
                    recordsState.selected_record_item = nil
                end
                imgui.Separator()

                if recordsState.selected_record then
                    if recordsState.selected_record.record_type == "Folder" then
                        renderFolderViewer(recordsState.selected_record)
                        
                        if recordsState.selected_record_item and recordsState.selected_record_item.data then
                            imgui.Separator()
                            imgui.Text("Item Details: " .. (recordsState.selected_record_item.display_name or ""))
                            
                            local item_type = recordsState.selected_record_item.record_type
                            if item_type == "Arrest" then renderArrestRecordViewer(recordsState.selected_record_item)
                            elseif item_type == "TCR" then renderTCRViewer(recordsState.selected_record_item)
                            elseif item_type == "Incident" then renderIncidentViewer(recordsState.selected_record_item)
                            elseif item_type == "Complaint" then renderComplaintViewer(recordsState.selected_record_item)
                            elseif item_type == "CCWSuspension" then renderCCWSuspensionViewer(recordsState.selected_record_item)
                            elseif item_type == "Property" then renderPropertyReportViewer(recordsState.selected_record_item)
							elseif item_type == "FollowUp" then renderFollowUpViewer(recordsState.selected_record_item)
                            end
                        end
                    else
                        local record_type = recordsState.selected_record.record_type
                        if record_type == "Arrest" then renderArrestRecordViewer(recordsState.selected_record)
                        elseif record_type == "TCR" then renderTCRViewer(recordsState.selected_record)
                        elseif record_type == "Incident" then renderIncidentViewer(recordsState.selected_record)
                        elseif record_type == "FollowUp" then renderFollowUpViewer(recordsState.selected_record)
                        elseif record_type == "Complaint" then renderComplaintViewer(recordsState.selected_record)
                        elseif record_type == "CCWSuspension" then renderCCWSuspensionViewer(recordsState.selected_record)
                        elseif record_type == "Property" then renderPropertyReportViewer(recordsState.selected_record)
                        else
                            imgui.Text("Preview for this report type is not implemented yet.")
                        end
                    end
                end

                imgui.PopStyleColor(1)
            elseif not active_rms_form then
                renderDashboard()

                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.0, 0.0, 0.0, 1.0))
                imgui.Text("Create New Report:")
                imgui.Separator()

                imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.9, 0.9, 0.9, 1.0))
                
                if imgui.Button("Complaint", imgui.new('ImVec2', 130, 30)) then recordsState.selected_record = nil; switchRMSForm('Complaint') end
                imgui.SameLine()
                if imgui.Button("CCW Suspension", imgui.new('ImVec2', 130, 30)) then recordsState.selected_record = nil; switchRMSForm('CCWSuspension') end
                imgui.SameLine()
                if imgui.Button("TCR", imgui.new('ImVec2', 130, 30)) then recordsState.selected_record = nil; switchRMSForm('TCR') end
                imgui.SameLine()
                if imgui.Button("Incident Report", imgui.new('ImVec2', 130, 30)) then recordsState.selected_record = nil; switchRMSForm('Incident') end
                imgui.SameLine()
                if imgui.Button("Arrest Record", imgui.new('ImVec2', 130, 30)) then recordsState.selected_record = nil; switchRMSForm('Arrest') end
                imgui.SameLine()
                if imgui.Button("Follow-Up Report", imgui.new('ImVec2', 130, 30)) then recordsState.selected_record = nil; switchRMSForm('FollowUp') end
                imgui.SameLine()
                if imgui.Button("Property Report", imgui.new('ImVec2', 130, 30)) then recordsState.selected_record = nil; switchRMSForm('Property') end
                
                imgui.Separator()
                if imgui.Button("Group Reports", imgui.new('ImVec2', 130, 30)) then
                    recordsState.groupingMode = true
                    recordsState.selected_record = nil
                end

                imgui.PopStyleColor(2)
            end

        imgui.EndChild()
        imgui.Columns(1)
        
        
        
        imgui.End() 
    end
    imgui.PopStyleColor(2)

    if active_rms_form == 'TCR' then renderTCRWindow()
    elseif active_rms_form == 'FollowUp' then renderFollowUpWindow()
    elseif active_rms_form == 'Arrest' then renderArrestWindow()
    elseif active_rms_form == 'Incident' then renderIncidentWindow()
    elseif active_rms_form == 'Complaint' then renderComplaintWindow()
    elseif active_rms_form == 'CCWSuspension' then renderCCWSuspensionWindow()
    elseif active_rms_form == 'Property' then renderPropertyReportWindow()
    end

    collectgarbage("restart")
    imgui.PopStyleColor(1)
end


rms_module.initialize = function(deps)
    core = deps.core
    log = deps.log
    settings = deps.settings
    safe_copy = deps.safe_copy
    log_levels = deps.log_levels
    websocket = deps.websocket
    json = deps.json
    events = deps.events
    rms_cursor_hotkey_enabled = settings.get('rms_settings', 'cursor_hotkey_enabled', true)

    sampRegisterChatCommand("rms", function()
        rms_module.toggleWindow()
    end)
    sampRegisterChatCommand("rmscursorhk", function()
        rms_cursor_hotkey_enabled = not rms_cursor_hotkey_enabled
        if settings then
            settings.set('rms_settings', 'cursor_hotkey_enabled', rms_cursor_hotkey_enabled)
            settings.save()
        end
        local status = rms_cursor_hotkey_enabled and "ENABLED" or "DISABLED"
        sampAddChatMessage(string.format("[RMS] Cursor hotkey (F4): %s", status), 0xFFFFFF)
    end)

    imgui.OnFrame(
        function() return is_rms_context_active() end,
        function(self)
            if rms_cursor_hotkey_enabled and is_rms_context_active() and imgui.IsKeyPressed(rms_cursor_hotkey, false) then
                rms_cursor_force_hidden = not rms_cursor_force_hidden
                log('RMS', log_levels.INFO, "RMS cursor toggled: " .. (rms_cursor_force_hidden and "hidden" or "visible"))
            end

            renderRMSWindow()
            renderCodebookWindow()

            local show_cursor = not rms_cursor_force_hidden
            self.HideCursor = not show_cursor
            if sampShowCursor and type(sampShowCursor) == 'function' then
                sampShowCursor(show_cursor)
            end
        end
    )

    
    
    events.register('rms:message', function(decoded_message)
        process_rms_message(decoded_message)
    end)
    
    
    
    events.register('broadcast:message', function(decoded_message)
        if decoded_message.dataType == 'rms_update' then
            log('RMS', log_levels.INFO, 'Received RMS update broadcast from server. Refreshing list.')
            
            if UI.rms_window and UI.rms_window[0] then
                requestReportsList()
            end
        end
    end)
        
    log('RMS', log_levels.INFO, "RMS Module Initialized. Type /rms to open.")
end

rms_module.toggleWindow = function()
    UI.rms_window[0] = not UI.rms_window[0]
    if not UI.rms_window[0] and not active_rms_form then
        rms_cursor_force_hidden = false
    end
    if UI.rms_window[0] then
        rms_cursor_force_hidden = false
        requestReportsList()
        requestDashboardData()
    end
    log('RMS', log_levels.INFO, "RMS window toggled: " .. tostring(UI.rms_window[0]))
end

return rms_module
