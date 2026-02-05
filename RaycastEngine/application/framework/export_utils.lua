-- ========================================
-- 文件: export_utils.lua
-- 功能: 导出功能所需的辅助工具函数
-- 说明: 如果 module_util 中已有这些功能,可忽略此文件
-- ========================================

local module = {}

local util = Engine.Util
local rl = Engine.Raylib

-- ========================================
-- 函数: 选择文件夹对话框
-- 参数: title - 对话框标题
-- 返回: 选中的文件夹路径,取消则返回nil
-- ========================================
module.SelectFolder = function(title)
    -- 如果 util.SelectFolder 不存在,这里提供备用实现
    if util.SelectFolder then
        return util.SelectFolder(title)
    end
    
    -- 备用方案: 使用命令行调用PowerShell文件夹选择对话框
    local ps_script = [[
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = ']] .. (title or "选择文件夹") .. [['
        $dialog.ShowNewFolderButton = $true
        if ($dialog.ShowDialog() -eq 'OK') {
            Write-Output $dialog.SelectedPath
        }
    ]]
    
    local temp_file = os.tmpname()
    local ps_file = temp_file .. ".ps1"
    
    -- 写入PowerShell脚本
    local f = io.open(ps_file, "w")
    if f then
        f:write(ps_script)
        f:close()
        
        -- 执行脚本并捕获输出
        local output_file = temp_file .. ".txt"
        local cmd = string.format('powershell -ExecutionPolicy Bypass -File "%s" > "%s"', ps_file, output_file)
        os.execute(cmd)
        
        -- 读取结果
        local result = nil
        f = io.open(output_file, "r")
        if f then
            result = f:read("*l")  -- 读取第一行
            if result then
                result = result:gsub("[\r\n]", "")  -- 去除换行符
            end
            f:close()
        end
        
        -- 清理临时文件
        os.remove(ps_file)
        os.remove(output_file)
        
        return result
    end
    
    return nil
end

-- ========================================
-- 函数: 选择文件对话框
-- 参数: title - 对话框标题
--       filter - 文件过滤器,如 "图像文件|*.png;*.jpg|所有文件|*.*"
-- 返回: 选中的文件路径,取消则返回nil
-- ========================================
module.SelectFile = function(title, filter)
    -- 如果 util.SelectFile 不存在,这里提供备用实现
    if util.SelectFile then
        return util.SelectFile(title, filter)
    end
    
    -- 备用方案: 使用PowerShell
    local ps_script = [[
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = ']] .. (title or "选择文件") .. [['
        if ($dialog.ShowDialog() -eq 'OK') {
            Write-Output $dialog.FileName
        }
    ]]
    
    local temp_file = os.tmpname()
    local ps_file = temp_file .. ".ps1"
    
    -- 写入PowerShell脚本
    local f = io.open(ps_file, "w")
    if f then
        f:write(ps_script)
        f:close()
        
        -- 执行脚本并捕获输出
        local output_file = temp_file .. ".txt"
        local cmd = string.format('powershell -ExecutionPolicy Bypass -File "%s" > "%s"', ps_file, output_file)
        os.execute(cmd)
        
        -- 读取结果
        local result = nil
        f = io.open(output_file, "r")
        if f then
            result = f:read("*l")
            if result then
                result = result:gsub("[\r\n]", "")
            end
            f:close()
        end
        
        -- 清理临时文件
        os.remove(ps_file)
        os.remove(output_file)
        
        return result
    end
    
    return nil
end

-- ========================================
-- 函数: 获取文件大小(字节)
-- ========================================
module.GetFileSize = function(path)
    local f = io.open(path, "rb")
    if not f then return 0 end
    local size = f:seek("end")
    f:close()
    return size
end

-- ========================================
-- 函数: 格式化文件大小为可读字符串
-- ========================================
module.FormatFileSize = function(bytes)
    if bytes < 1024 then
        return string.format("%d B", bytes)
    elseif bytes < 1024 * 1024 then
        return string.format("%.2f KB", bytes / 1024)
    elseif bytes < 1024 * 1024 * 1024 then
        return string.format("%.2f MB", bytes / (1024 * 1024))
    else
        return string.format("%.2f GB", bytes / (1024 * 1024 * 1024))
    end
end

return module
